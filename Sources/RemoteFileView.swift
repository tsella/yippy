import SwiftUI

/// Details for a non-directory entry in the filesystem browser.
///
/// Exists so that tapping a file does not issue a `LIST_DIRECTORY` for it.
/// The camera answers that with `-26`, which is harmless but costs a round
/// trip on a channel that must stay quiet, and leaves the user on an empty
/// "nothing to list here" screen.
struct RemoteFileView: View {
    let entry: FilesystemExplorer.Entry
    let onDownload: () -> Void

    private var isDownloadable: Bool {
        YiFile.isServedOverHTTP(entry.path)
    }

    var body: some View {
        List {
            Section("File") {
                LabeledContent("Name", value: entry.name)
                if entry.size > 0 {
                    LabeledContent("Size",
                                   value: ByteCountFormatter.string(fromByteCount: entry.size,
                                                                    countStyle: .file))
                }
                LabeledContent("Path") {
                    Text(entry.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                Button {
                    onDownload()
                } label: {
                    Label("Save to Files", systemImage: "arrow.down.doc")
                }
                .disabled(!isDownloadable)
            } footer: {
                // The camera's HTTP server only exposes the SD card, so
                // firmware paths cannot be fetched at all. Say so rather than
                // offering a button that can only 404.
                Text(isDownloadable
                     ? "Saves to the Files app, under On My iPhone → Yippy!."
                     : "The camera only serves files from its SD card over HTTP, so this path cannot be downloaded.")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
