import SwiftUI

/// Interactive one-directory-at-a-time browser.
///
/// Lists exactly one directory per request, so tapping into a folder costs a
/// single `1282` call — the pacing a fragile control channel needs. Nothing is
/// excluded: `/proc`, `/sys` and `/dev` open like any other directory.
struct DirectoryBrowserView: View {
    @ObservedObject var client: YiCameraClient
    @ObservedObject var fileManager: YiFileManager
    /// Stateless over the client, so it needs no observation of its own — the
    /// listing it returns lives in `entries` below.
    private let explorer: FilesystemExplorer

    @State private var path: String
    @State private var entries: [FilesystemExplorer.Entry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    /// Set when the camera answers -26 for this path — it is a file, and the
    /// listing that proved it is the fallback the user suggested.
    @State private var notADirectory = false

    init(client: YiCameraClient, fileManager: YiFileManager, path: String = "/") {
        self.client = client
        self.fileManager = fileManager
        _path = State(initialValue: path)
        explorer = FilesystemExplorer(client: client)
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
            } else if notADirectory {
                // The camera answered -26: this path is a file. Offer the file
                // actions here rather than leaving an empty list.
                Section {
                    Label("This is a file, not a directory.", systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        download(FilesystemExplorer.Entry(
                            path: path, name: displayName,
                            isDirectory: false, isMarkedDirectory: false,
                            size: 0, depth: 0
                        ))
                    } label: {
                        // Files, never Photos — the browser reaches firmware
                        // data the photo library would reject.
                        Label("Save to Files", systemImage: "arrow.down.doc")
                    }
                    .disabled(!YiFile.isServedOverHTTP(path))
                } footer: {
                    if !YiFile.isServedOverHTTP(path) {
                        Text("The camera only serves files from its SD card over HTTP, so this path cannot be downloaded.")
                    }
                }
            } else if entries.isEmpty && errorText == nil && !isLoading {
                Text("This directory is empty.")
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // The camera marks directories with a trailing slash, so an entry
            // without one is a file. Listing it would return -26 — harmless,
            // but a wasted round trip on a fragile channel and an empty screen
            // for the user.
            ForEach(sorted) { entry in
                if entry.isMarkedDirectory {
                    NavigationLink {
                        DirectoryBrowserView(client: client, fileManager: fileManager, path: entry.path)
                    } label: {
                        row(entry)
                    }
                } else if entry.isImage {
                    NavigationLink {
                        RemoteImageView(path: entry.path, name: entry.name)
                    } label: {
                        row(entry)
                    }
                    .swipeActions(edge: .trailing) { downloadButton(entry) }
                    .contextMenu { downloadButton(entry) }
                } else if entry.isMedia || entry.size > 0 {
                    // A plain file: show its details rather than listing it.
                    NavigationLink {
                        RemoteFileView(entry: entry) { download(entry) }
                    } label: {
                        row(entry)
                    }
                    .swipeActions(edge: .trailing) { downloadButton(entry) }
                    .contextMenu { downloadButton(entry) }
                } else {
                    // Genuinely ambiguous — no directory marker and no size.
                    // Browse it: if the camera answers -26, that view falls
                    // back to showing it as a file.
                    NavigationLink {
                        DirectoryBrowserView(client: client, fileManager: fileManager, path: entry.path)
                    } label: {
                        row(entry)
                    }
                    .swipeActions(edge: .trailing) { downloadButton(entry) }
                    .contextMenu { downloadButton(entry) }
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
        // Downloads report through the file manager, so the browser has to
        // present that too — without this the button appeared to do nothing,
        // since both success and failure were being discarded here.
        .overlay {
            if let file = fileManager.downloadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: fileManager.downloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 180)
                        Text(file.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Cancel", role: .cancel) { fileManager.cancelDownload() }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let saved = fileManager.savedMessage {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 16)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        fileManager.savedMessage = nil
                    }
            }
        }
        .alert("Download Failed",
               isPresented: .init(get: { fileManager.errorMessage != nil },
                                  set: { if !$0 { fileManager.errorMessage = nil } })) {
            Button("OK") { fileManager.errorMessage = nil }
        } message: {
            Text(fileManager.errorMessage ?? "")
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

    @ViewBuilder
    private func downloadButton(_ entry: FilesystemExplorer.Entry) -> some View {
        Button {
            download(entry)
        } label: {
            Label("Download", systemImage: "square.and.arrow.down")
        }
        .tint(.blue)
    }

    /// Saves an arbitrary camera file to the Files app.
    ///
    /// Not the photo library: the browser reaches firmware data (`.bin`,
    /// `.pcm`, `.conf`) that Photos rejects outright. Documents is visible
    /// under "On My iPhone → Yippy!".
    private func download(_ entry: FilesystemExplorer.Entry) {
        let file = YiFile(name: entry.name, path: entry.path,
                          size: entry.size, date: nil)
        fileManager.downloadToFiles(file)
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
            notADirectory = false
        } catch {
            entries = []
            // -26 means this path is not a directory. When the camera did not
            // mark it either way, that answer is the classification: show it
            // as a file rather than an error.
            if case YiCameraError.commandFailed(_, let rval) = error,
               rval == YiReturnCode.notADirectory {
                notADirectory = true
                errorText = nil
            } else {
                notADirectory = false
                errorText = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
            }
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
