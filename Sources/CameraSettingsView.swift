import SwiftUI

/// Capture settings, read from and written to the camera.
///
/// The available keys and their legal values differ across firmwares, so
/// nothing here is hardcoded: the current values come from
/// `GET_ALL_CURRENT_SETTINGS` (3) and each picker's choices from
/// `GET_SINGLE_SETTING_OPTIONS` (9). A setting the camera does not report is
/// simply not shown.
struct CameraSettingsView: View {
    @ObservedObject var client: YiCameraClient

    @State private var settings: [String: String] = [:]
    @State private var options: [String: [String]] = [:]
    @State private var isLoading = false
    @State private var pendingKey: String?
    @State private var errorText: String?

    /// Settings worth exposing, in display order. Anything else the camera
    /// reports is available under "All settings" for reference.
    private static let curated: [(key: String, label: String, icon: String)] = [
        ("video_resolution", "Video Resolution", "video"),
        ("video_quality",    "Video Quality",    "dial.high"),
        ("photo_size",       "Photo Size",       "photo"),
        ("photo_quality",    "Photo Quality",    "sparkles"),
        ("capture_mode",     "Capture Mode",     "camera.aperture"),
        ("meter_mode",       "Metering",         "circle.lefthalf.filled"),
        ("video_standard",   "Video Standard",   "globe"),
        ("auto_low_light",   "Auto Low Light",   "moon"),
        ("loop_record",      "Loop Recording",   "arrow.triangle.2.circlepath"),
        ("video_stamp",      "Video Timestamp",  "calendar"),
        ("photo_stamp",      "Photo Timestamp",  "calendar"),
        ("warp_enable",      "Distortion Correction", "grid"),
        ("led_mode",         "Status LED",       "lightbulb"),
        ("buzzer_volume",    "Buzzer Volume",    "speaker.wave.2"),
        ("auto_power_off",   "Auto Power Off",   "power"),
    ]

    private var availableSettings: [(key: String, label: String, icon: String)] {
        Self.curated.filter { settings[$0.key] != nil }
    }

    var body: some View {
        Form {
            if isLoading && settings.isEmpty {
                HStack { ProgressView(); Text("Reading settings…").foregroundStyle(.secondary) }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !availableSettings.isEmpty {
                Section("Capture") {
                    ForEach(availableSettings, id: \.key) { item in
                        settingRow(key: item.key, label: item.label, icon: item.icon)
                    }
                }
            }

            if !settings.isEmpty {
                Section("All Settings") {
                    // Everything the camera reports, including keys with no
                    // picker — useful for identifying what a firmware supports.
                    ForEach(settings.keys.sorted(), id: \.self) { key in
                        LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized,
                                       value: settings[key] ?? "")
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Camera Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func settingRow(key: String, label: String, icon: String) -> some View {
        let current = settings[key] ?? ""
        let choices = options[key] ?? []

        if choices.count > 1 {
            Picker(selection: Binding(
                get: { current },
                set: { newValue in
                    guard newValue != current else { return }
                    Task { await apply(key: key, value: newValue) }
                }
            )) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            } label: {
                Label(label, systemImage: icon)
            }
            .disabled(pendingKey != nil)
        } else {
            // No options reported: show the value read-only rather than
            // pretending it can be changed.
            LabeledContent {
                if pendingKey == key {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(current).foregroundStyle(.secondary)
                }
            } label: {
                Label(label, systemImage: icon)
            }
        }
    }

    private func load() async {
        guard client.isConnected else {
            errorText = "Camera not connected."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        settings = await client.allSettings()
        if settings.isEmpty {
            errorText = "The camera did not report any settings."
            return
        }

        // Fetch the legal values for each curated key that exists. Sequential
        // rather than parallel: the camera's control channel is single-threaded
        // and floods poorly.
        for item in availableSettings where options[item.key] == nil {
            let choices = await client.settingOptions(for: item.key)
            if !choices.isEmpty { options[item.key] = choices }
        }
    }

    private func apply(key: String, value: String) async {
        pendingKey = key
        defer { pendingKey = nil }

        do {
            try await client.setSetting(key, to: value)
            // Re-read rather than assuming it took: the camera silently clamps
            // some combinations (e.g. a resolution the current mode disallows).
            // One key, not the whole table — the link is slow.
            let actual = await client.setting(key)
            settings[key] = actual ?? settings[key]
            if let actual, actual != value {
                errorText = "The camera kept \(actual) for \(key)."
            } else {
                errorText = nil
            }
        } catch {
            errorText = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
            settings[key] = await client.setting(key) ?? settings[key]
        }
    }
}
