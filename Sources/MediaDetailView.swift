import SwiftUI

/// Full-screen viewer for a single item.
///
/// Opens showing the already-cached `.THM` preview so there is something on
/// screen immediately, then loads the full-resolution image over it. Videos
/// cannot be played in place — the camera serves them over plain HTTP and they
/// are large — so they offer Save to Photos instead.
struct MediaDetailView: View {
    let file: YiFile
    let onDelete: () -> Void
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var preview: UIImage?
    @State private var isLoading = false
    @State private var confirmingDelete = false

    /// Derived rather than stored: it is exactly "nothing loaded and not still
    /// trying", so a separate flag could only drift out of sync.
    private var loadFailed: Bool {
        !isLoading && fullImage == nil && preview == nil
    }

    // Zoom state.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            onSave()
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmation(
                isPresented: $confirmingDelete,
                title: "Delete \(file.name)?",
                message: "This permanently removes the file from the camera's SD card.",
                confirmTitle: "Delete"
            ) {
                onDelete()
                dismiss()
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if file.isVideo {
            videoPlaceholder
        } else if let shown = fullImage ?? preview {
            imageViewer(shown)
        } else if loadFailed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Could not load this image.")
                    .foregroundStyle(.white)
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private func imageViewer(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in scale = min(max(lastScale * value, 1), 6) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1 { resetZoom() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                // Double-tap toggles zoom, the standard photo-viewer gesture.
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) {
                        if scale > 1 { resetZoom() } else { scale = 3; lastScale = 3 }
                    }
                }
                .overlay(alignment: .bottom) {
                    if isLoading {
                        // The .THM preview is low-resolution; say so while the
                        // full image is still downloading.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text("Loading full resolution…")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 24)
                    }
                }
        }
    }

    private var videoPlaceholder: some View {
        VStack(spacing: 16) {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.gray)
            }

            Text(file.name).foregroundStyle(.white)
            Text(file.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onSave()
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)

            Text("Playback in the app is not supported — save the video to view it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func resetZoom() {
        scale = 1; lastScale = 1
        offset = .zero; lastOffset = .zero
    }

    private func load() async {
        // Show the cached grid preview instantly, if there is one.
        preview = ThumbnailLoader.shared.cached(for: file)

        guard !file.isVideo else {
            if preview == nil { preview = await ThumbnailLoader.shared.thumbnail(for: file) }
            return
        }

        isLoading = true
        defer { isLoading = false }
        fullImage = await ThumbnailLoader.shared.fullImage(for: file)
    }
}
