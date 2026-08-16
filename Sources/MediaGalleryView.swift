import SwiftUI

struct MediaGalleryView: View {
    @ObservedObject var fileManager: YiFileManager
    @ObservedObject var client: YiCameraClient
    @State private var fileToDelete: YiFile?
    @State private var selectedFile: YiFile?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)]

    var body: some View {
        Group {
            if fileManager.isLoading && fileManager.files.isEmpty {
                ProgressView("Loading media…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileManager.files.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Gallery")
        .task {
            // Only load on first appearance; pull-to-refresh handles the rest.
            if fileManager.files.isEmpty { await fileManager.listFiles() }
        }
        // The camera pushes photo_taken / video_record_complete when new media
        // lands on the card, so the gallery refreshes itself instead of polling.
        .onChange(of: client.mediaChangeCount) { _ in
            Task { await fileManager.listFiles() }
        }
        .overlay { downloadOverlay }
        .fullScreenCover(item: $selectedFile) { file in
            MediaDetailView(file: file) {
                Task { await fileManager.deleteFile(file) }
            } onSave: {
                fileManager.downloadFile(file)
            }
        }
        .confirmation(
            isPresented: .init(get: { fileToDelete != nil },
                               set: { if !$0 { fileToDelete = nil } }),
            title: "Delete \(fileToDelete?.name ?? "file")?",
            message: "This permanently removes the file from the camera's SD card.",
            confirmTitle: "Delete"
        ) {
            // Capture before the binding clears it.
            if let file = fileToDelete {
                Task { await fileManager.deleteFile(file) }
            }
        }
        .alert("Error", isPresented: .init(get: { fileManager.errorMessage != nil },
                                           set: { if !$0 { fileManager.errorMessage = nil } })) {
            Button("OK") { fileManager.errorMessage = nil }
        } message: {
            Text(fileManager.errorMessage ?? "")
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        fileManager.savedMessage = nil
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: fileManager.savedMessage)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            Text("No Media Found")
                .font(.title2.bold())
            Text("Capture some photos or videos with your camera first.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Refresh") {
                Task { await fileManager.listFiles() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            // Photos are 4:3 and videos 16:9, so cells in a row differ in
            // height. Top-align them rather than letting each stretch to the
            // row height, which would detach the caption from its thumbnail.
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(fileManager.files) { file in
                    MediaCard(file: file) {
                        fileManager.downloadFile(file)
                    } onDelete: {
                        fileToDelete = file
                    } onOpen: {
                        selectedFile = file
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding()
        }
        .refreshable { await fileManager.listFiles() }
    }

    @ViewBuilder
    private var downloadOverlay: some View {
        if let file = fileManager.downloadingFile {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView(value: fileManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("Downloading \(file.name)")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(Int(fileManager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancel", role: .cancel) { fileManager.cancelDownload() }
                        .padding(.top, 4)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)
            }
        }
    }
}

struct MediaCard: View {
    let file: YiFile
    let onDownload: () -> Void
    let onDelete: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(file: file)
                .contentShape(Rectangle())
                .onTapGesture { onOpen?() }

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let date = file.date {
                            Text(date, format: .dateTime.day().month().year())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button(action: onDownload) {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .foregroundStyle(.gray)
                            .font(.system(size: 18))
                    }
                    .accessibilityLabel("Actions for \(file.name)")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}
