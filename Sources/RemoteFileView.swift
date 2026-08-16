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
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            } footer: {
                // Anything outside DCIM is firmware data, and Photos will
                // reject it — say so rather than letting the save fail opaquely.
                Text(entry.isMedia
                     ? "Saves this file to your photo library."
                     : "Photos only accepts images and videos, so this will likely fail for firmware files.")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
