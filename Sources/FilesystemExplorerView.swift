import SwiftUI

struct FilesystemExplorerView: View {
    @ObservedObject var client: YiCameraClient
    @ObservedObject var fileManager: YiFileManager
    @StateObject private var explorer: FilesystemExplorer

    @State private var root = "/"
    @State private var depth = 3
    @State private var showingLog = false
    @FocusState private var rootFocused: Bool

    init(client: YiCameraClient, fileManager: YiFileManager) {
        self.client = client
        self.fileManager = fileManager
        _explorer = StateObject(wrappedValue: FilesystemExplorer(client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if showingLog {
                logList
            } else {
                resultList
            }
        }
        .navigationTitle("Filesystem")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Picker("View", selection: $showingLog) {
                Text("Tree").tag(false)
                Text("Log").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Label(
                "Walks the camera's Linux filesystem breadth-first. Nothing is excluded — /proc, /sys and /dev are included and can be very large. Start shallow. Tap a folder to browse it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Root:")
                TextField("/", text: $root)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($rootFocused)
                    .frame(maxWidth: 140)

                Spacer()

                Stepper("Depth \(depth)", value: $depth, in: 1...6)
                    .fixedSize()
            }

            HStack {
                if explorer.isRunning {
                    Button("Stop", role: .destructive) { explorer.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Explore") {
                        rootFocused = false
                        let path = root.trimmingCharacters(in: .whitespaces)
                        explorer.explore(root: path.isEmpty ? "/" : path, maxDepth: depth)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!client.isConnected)
                }

                Spacer()

                if !explorer.entries.isEmpty {
                    Text("\(explorer.entries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if explorer.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(explorer.progress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !client.isConnected {
                Text("Camera must be connected.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
    }

    /// Entries grouped by depth, mirroring how the walk actually proceeds.
    private var resultList: some View {
        // Grouped once per body pass. Filtering per section instead would
        // rescan all entries (capped at 20,000) for every depth, on every
        // update — and updates fire on each entry appended during a walk.
        let grouped = Dictionary(grouping: explorer.entries, by: \.depth)

        return List {
            if explorer.entries.isEmpty {
                Text(explorer.isRunning ? "Walking…" : "No results yet. Tap Explore.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(grouped.keys.sorted(), id: \.self) { level in
                    Section("Depth \(level)") {
                        // Every row is tappable — directory detection from a
                        // listing is unreliable, so don't gate navigation on it.
                        ForEach(grouped[level] ?? []) { entry in
                            NavigationLink {
                                DirectoryBrowserView(client: client, fileManager: fileManager, path: entry.path)
                            } label: {
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ entry: FilesystemExplorer.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if entry.size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        // No .textSelection here — it intercepts the row's tap gesture and
        // stops NavigationLink from ever firing.
        .contentShape(Rectangle())
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(explorer.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}
