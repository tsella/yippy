import SwiftUI

struct DebugScannerView: View {
    @ObservedObject var client: YiCameraClient
    @ObservedObject var fileManager: YiFileManager
    @State private var startId = "1"
    @State private var endId = "500"
    @FocusState private var focusedField: Field?

    private enum Field { case start, end }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                DirectoryBrowserView(client: client, fileManager: fileManager)
            } label: {
                Label("Browse Filesystem", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            }
            Divider()

            controls

            if !client.isConnected {
                Label("Camera must be connected to run the scanner.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }

            logList
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Label(
                "Probes undocumented commands. Unknown msg_ids can hang or reboot the camera's TCP server.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Range:")
                TextField("Start", text: $startId)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .start)
                Text("to")
                TextField("End", text: $endId)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focusedField, equals: .end)

                Spacer()

                if client.isScanning {
                    Button("Stop", role: .destructive) { client.cancelScan() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        focusedField = nil
                        client.scanUndocumentedCommands(range: scanRange)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!client.isConnected)
                }
            }

            if client.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    /// Clamps user input to a sane, ordered range.
    private var scanRange: ClosedRange<Int> {
        let start = max(1, Int(startId) ?? 1)
        let end = min(max(start, Int(endId) ?? 500), 65535)
        return start...end
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if client.scanLogs.isEmpty {
                    Text("No logs yet. Tap Start to search for undocumented commands.")
                        .foregroundStyle(.secondary)
                        .italic()
                        .padding(.top)
                } else {
                    ForEach(Array(client.scanLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
