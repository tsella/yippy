import SwiftUI

/// Interactive one-directory-at-a-time browser.
///
/// Distinct from `FilesystemExplorerView`, which walks many levels at once:
/// this lists exactly one directory per request, so tapping into a folder costs
/// a single `1282` call. Nothing is excluded — `/proc`, `/sys` and `/dev` can be
/// opened like any other directory.
struct DirectoryBrowserView: View {
    @ObservedObject var client: YiCameraClient
    @StateObject private var explorer: FilesystemExplorer

    @State private var path: String
    @State private var entries: [FilesystemExplorer.Entry] = []
    @State private var isLoading = false
    @State private var errorText: String?

    init(client: YiCameraClient, path: String = "/") {
        self.client = client
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

            // Every row is a link, including ones that look like files.
            // Directory detection from a listing is unreliable — a Linux
            // directory commonly reports a real size ("4096 bytes"), which is
            // indistinguishable from a file. Rather than guess and leave real
            // directories un-tappable, let the camera decide: opening a plain
            // file simply lists nothing.
            ForEach(sorted) { entry in
                NavigationLink {
                    DirectoryBrowserView(client: client, path: entry.path)
                } label: {
                    row(entry)
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
