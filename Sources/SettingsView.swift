import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: YiCameraClient
    @AppStorage("showDebugScanner") private var showDebugScanner = false

    @State private var deviceInfo: [(key: String, value: String)] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var confirmingFormat = false
    @State private var confirmingPowerOff = false
    @State private var cardSpace: (total: Int64, free: Int64)?
    @State private var checkedSpace = false
    @State private var cameraClock: Date?
    @State private var isSyncingClock = false
    @State private var logo: UIImage?
    @AppStorage(YiCameraClient.syncClockDefaultsKey) private var syncClockOnConnect = true

    private static let keyNames: [String: String] = [
        "fw_ver": "Firmware Version",
        "api_ver": "API Version",
        "app_type": "App Type",
        "model": "Model",
        "brand": "Brand",
        "chip": "Chipset",
        "sn": "Serial Number",
    ]

    private static let hiddenKeys: Set<String> = ["msg_id", "rval", "logo", "token"]

    var body: some View {
        Form {
            if let logo {
                Section {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 90)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Camera logo")
                }
                .listRowBackground(Color.clear)
            }

            deviceSection

            Section("Camera") {
                NavigationLink {
                    CameraSettingsView(client: client)
                } label: {
                    Label("Capture Settings", systemImage: "camera")
                }
            }

            Section {
                Toggle("Sync Clock on Connect", isOn: $syncClockOnConnect)

                if let clock = cameraClock {
                    LabeledContent("Camera Time") {
                        Text(clock, format: .dateTime.year().month().day().hour().minute().second())
                            .foregroundStyle(abs(clock.timeIntervalSinceNow) > 120 ? .orange : .secondary)
                    }
                }

                Button {
                    Task {
                        isSyncingClock = true
                        defer { isSyncingClock = false }
                        if await client.syncClock() {
                            cameraClock = await client.cameraClock()
                        }
                    }
                } label: {
                    HStack {
                        Label("Sync Clock Now", systemImage: "clock.arrow.2.circlepath")
                        if isSyncingClock {
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .disabled(isSyncingClock)
            } header: {
                Text("Date & Time")
            } footer: {
                // Explains why this matters: without an RTC the camera forgets
                // the time whenever the battery is removed.
                Text("The camera has no backup battery for its clock, so it loses the time when the battery is removed. Media timestamps are only as accurate as the last sync.")
            }

            Section("Developer") {
                Toggle("API Scanner", isOn: $showDebugScanner)
                if showDebugScanner {
                    Text("Probes undocumented commands. Unknown commands can hang or reboot the camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                if let space = cardSpace {
                    LabeledContent("Total",
                                   value: ByteCountFormatter.string(fromByteCount: space.total, countStyle: .file))
                    LabeledContent("Free",
                                   value: ByteCountFormatter.string(fromByteCount: space.free, countStyle: .file))
                    if space.total == 0 {
                        // The camera answered but sees no capacity: the card is
                        // not mounted, so on-camera formatting cannot help.
                        Text("The camera cannot mount this card. Repartition it on a computer — see the README. Formatting here will not fix it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if checkedSpace {
                    Text("No card detected.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button(role: .destructive) {
                    confirmingFormat = true
                } label: {
                    Label("Format SD Card", systemImage: "trash.slash.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingPowerOff = true
                } label: {
                    Label("Power Off Camera", systemImage: "power")
                }

                Button("Disconnect") {
                    client.disconnect()
                }
            }
        }
        .navigationTitle("Settings")
        .task { await loadDeviceInfo() }
        .refreshable { await loadDeviceInfo() }
        // Irreversible: erases the card with no recovery path.
        .confirmation(
            isPresented: $confirmingFormat,
            title: "Format SD Card?",
            message: "This permanently deletes every photo and video on the card. This cannot be undone.",
            confirmTitle: "Erase Everything"
        ) {
            client.formatSDCard()
        }
        .confirmation(
            isPresented: $confirmingPowerOff,
            title: "Power Off Camera?",
            message: "You will need to switch the camera on by hand to reconnect.",
            confirmTitle: "Power Off"
        ) {
            client.powerOff()
        }
    }

    private var deviceSection: some View {
        Section("Device Information") {
            if isLoading && deviceInfo.isEmpty {
                HStack {
                    ProgressView()
                    Text("Fetching…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if deviceInfo.isEmpty {
                Text("No device information available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceInfo, id: \.key) { item in
                    LabeledContent(item.key, value: item.value)
                }
            }
        }
    }

    private func loadDeviceInfo() async {
        guard client.isConnected else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let response = try await client.send(.getDeviceInfo)
            deviceInfo = response
                .filter { !Self.hiddenKeys.contains($0.key) }
                .map { key, value in
                    let name = Self.keyNames[key]
                        ?? key.replacingOccurrences(of: "_", with: " ").capitalized
                    return (key: name, value: "\(value)")
                }
                .sorted { $0.key < $1.key }

            // The firmware reports an artwork path in `logo`; it is hidden from
            // the key list and shown as a header instead.
            if let raw = response["logo"] {
                print("[settings] logo field: \(raw)")
            }
            if let url = YiCameraClient.logoURL(from: response) {
                logo = await ThumbnailLoader.shared.logo(from: url)
                if logo == nil { print("[settings] logo fetch failed for \(url)") }
            }

            cardSpace = await client.cardSpace()
            checkedSpace = true
            cameraClock = await client.cameraClock()
        } catch {
            loadError = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
        }
    }
}
