import SwiftUI

/// Interactive one-directory-at-a-time browser.
///
/// Distinct from `FilesystemExplorerView`, which walks many levels at once:
/// this lists exactly one directory per request, so tapping into a folder costs
/// a single `1282` call. Nothing is excluded — `/proc`, `/sys` and `/dev` can be
/// opened like any other directory.
struct DirectoryBrowserView: View {
    @ObservedObject var client: YiCameraClient
    @ObservedObject var fileManager: YiFileManager
    @StateObject private var explorer: FilesystemExplorer

    @State private var path: String
    @State private var entries: [FilesystemExplorer.Entry] = []
    @State private var isLoading = false
    @State private var errorText: String?

    init(client: YiCameraClient, fileManager: YiFileManager, path: String = "/") {
        self.client = client
        self.fileManager = fileManager
        _path = State(initialValue: path)
        _explorer = StateObject(wrappedValue: FilesystemExplorer(client: client))
    }

    var body: some View {
        List {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isLoading && entries.isEmpty {
                HStack { ProgressView(); Text("Listing…").foregroundStyle(.secondary) }
            } else if entries.isEmpty && errorText == nil && !isLoading {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing to list here.")
                        .foregroundStyle(.secondary)
                        .italic()
                    Text("This is either an empty directory or a regular file.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(sorted) { entry in
                if entry.isImage && entry.isDownloadable {
                    // Images open in a viewer rather than listing as a path.
                    NavigationLink {
                        RemoteImageView(path: entry.path, name: entry.name)
                    } label: {
                        row(entry)
                    }
                } else if entry.isDownloadable {
                    // A file the camera did not mark as a directory. Tapping
                    // still browses — the marker is absent on some firmwares —
                    // but a download action is offered alongside.
                    NavigationLink {
                        DirectoryBrowserView(client: client, fileManager: fileManager, path: entry.path)
                    } label: {
                        row(entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            download(entry)
                        } label: {
                            Label("Download", systemImage: "square.and.arrow.down")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            download(entry)
                        } label: {
                            Label("Download", systemImage: "square.and.arrow.down")
                        }
                    }
                } else {
                    NavigationLink {
                        DirectoryBrowserView(client: client, fileManager: fileManager, path: entry.path)
                    } label: {
                        row(entry)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .safeAreaInset(edge: .top) {
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                .textSelection(.enabled)
        }
        .task { await load() }
    }

    private var displayName: String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    private var sorted: [FilesystemExplorer.Entry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Saves an arbitrary camera file to the photo library.
    ///
    /// Reuses the gallery's download path by describing the entry as a
    /// `YiFile`, so staging, saving and cleanup behave identically.
    private func download(_ entry: FilesystemExplorer.Entry) {
        let file = YiFile(name: entry.name, path: entry.path,
                          size: entry.size, date: nil)
        fileManager.downloadFile(file)
    }

    private func load() async {
        // .task, .refreshable and the Refresh button can all fire this, and
        // SwiftUI re-runs .task on identity changes — without this guard they
        // stack up into a burst of identical listings.
        guard !isLoading else { return }
        guard client.isConnected else {
            errorText = "Camera not connected."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            entries = try await explorer.list(directory: path, depth: 0)
        } catch {
            entries = []
            errorText = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func row(_ entry: FilesystemExplorer.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 18)

            Text(entry.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

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
}
