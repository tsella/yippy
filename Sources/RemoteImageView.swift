import SwiftUI

/// Displays an image fetched from an arbitrary path on the camera.
///
/// Used by the filesystem browser, where entries are plain paths rather than
/// gallery media — so this cannot reuse `MediaDetailView`, which is built
/// around a `YiFile` and its sidecar previews.
struct RemoteImageView: View {
    let path: String
    let name: String

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorText: String?

    // Zoom state, matching the gallery viewer's gestures.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = min(max(lastScale * $0, 1), 6) }
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
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(duration: 0.3)) {
                                if scale > 1 { resetZoom() } else { scale = 3; lastScale = 3 }
                            }
                        }
                }
            } else if isLoading {
                ProgressView().tint(.white)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorText ?? "Could not load this image.")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 24)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private func resetZoom() {
        scale = 1; lastScale = 1
        offset = .zero; lastOffset = .zero
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        guard let url = YiFile.httpURL(forCameraPath: path) else {
            errorText = "Could not build a URL for this path."
            return
        }
        // Downsampled: files outside DCIM can be any size, and a full-resolution
        // decode of an unexpectedly large image would be a memory spike.
        guard let data = await ThumbnailLoader.fetch(url, timeout: 30) else {
            errorText = "The camera did not serve this file over HTTP."
            return
        }
        guard let decoded = ThumbnailLoader.downsampled(data, maxPixel: 2048) else {
            errorText = "This file is not a readable image."
            return
        }
        image = decoded
    }
}
