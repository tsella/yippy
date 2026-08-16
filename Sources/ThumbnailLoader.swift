import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Loads and caches gallery thumbnails from the camera's HTTP file server.
///
/// There is no documented thumbnail endpoint on this firmware, so previews come
/// from the full-size JPEG at `http://192.168.42.1/<path>`. Those are several
/// megabytes each over a slow link, so:
///
///  - Only photos are fetched. A video preview would mean pulling hundreds of
///    megabytes to decode one frame, which the camera's HTTP server cannot do
///    a range request for reliably.
///  - Decoding goes through `CGImageSourceCreateThumbnailAtIndex`, which
///    downsamples during decode rather than after — a full-resolution `UIImage`
///    per cell would exhaust memory in a grid.
///  - Results are cached in memory and requests are capped, so scrolling does
///    not queue dozens of concurrent multi-megabyte downloads.
@MainActor
final class ThumbnailLoader: ObservableObject {

    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    /// Full-resolution images for the detail viewer. Kept tiny — each is ~16MB.
    private let fullImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 2
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Bounded so a fast scroll cannot saturate the camera's HTTP server.
    private let concurrencyLimit = 3
    private var activeCount = 0
    /// Tasks parked waiting for a slot. Resuming a continuation is immediate,
    /// unlike polling a counter, which both wakes the actor repeatedly while
    /// blocked and adds latency after a slot frees.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSlot() async {
        if activeCount < concurrencyLimit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount -= 1
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// `nonisolated` so the off-actor decode can read it.
    private nonisolated static let maxPixelSize = 300

    private init() {
        cache.countLimit = 200
        // Roughly 300x300 RGBA ≈ 360KB each; cap total residency.
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(for file: YiFile) -> UIImage? {
        cache.object(forKey: file.path as NSString)
    }

    /// Fetches a downsampled preview.
    ///
    /// Prefers the camera's `.THM` sidecar — a small JPEG written beside every
    /// photo *and* video, so videos get a real preview without downloading
    /// hundreds of megabytes. Falls back to the original for photos when no
    /// sidecar exists.
    func thumbnail(for file: YiFile) async -> UIImage? {
        // Sidecar first, then the original for photos. Videos have no fallback:
        // decoding a frame would mean fetching the whole file.
        let candidates = [file.thumbnailURL, file.isVideo ? nil : file.downloadURL]
            .compactMap { $0 }
        guard !candidates.isEmpty else { return nil }

        let key = file.path
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { [weak self] () -> UIImage? in
            guard let self else { return nil }
            await self.acquireSlot()
            defer { self.releaseSlot(); self.inFlight[key] = nil }

            for url in candidates {
                guard !Task.isCancelled else { return nil }
                guard let data = await Self.fetch(url, timeout: 20),
                      let image = Self.downsampled(data) else { continue }
                self.cache.setObject(image, forKey: key as NSString,
                                     cost: Int(image.size.width * image.size.height * 4))
                return image
            }
            return nil
        }

        inFlight[key] = task
        return await task.value
    }

    /// Fetches a URL from the camera's HTTP file server.
    /// Returns `nil` on any transport error or non-2xx status.
    nonisolated static func fetch(_ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data
    }

    /// Decodes straight to thumbnail size — never materialises the full image.
    nonisolated static func downsampled(_ data: Data, maxPixel: Int? = nil) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Downloads a photo at full resolution for the detail viewer.
    ///
    /// Still downsampled — to 2048px rather than the grid's 300px — because a
    /// 4608x3456 image decoded at native size is ~64MB in memory, enough to be
    /// jettisoned on older devices. Not cached: these are large and viewed once.
    func fullImage(for file: YiFile) async -> UIImage? {
        guard !file.isVideo, let url = file.downloadURL else { return nil }
        if let hit = fullImageCache.object(forKey: file.path as NSString) { return hit }
        guard let data = await Self.fetch(url, timeout: 60),
              let image = Self.downsampled(data, maxPixel: 2048) else { return nil }
        // Browsing back and forth through a gallery re-opens the same photo, so
        // a tiny cache avoids re-pulling multi-megabyte originals over the link.
        fullImageCache.setObject(image, forKey: file.path as NSString)
        return image
    }

    /// Drops cached previews for files that no longer exist.
    func invalidate(_ file: YiFile) {
        cache.removeObject(forKey: file.path as NSString)
        inFlight[file.path]?.cancel()
        inFlight[file.path] = nil
    }
}

/// Preview of the shot just captured, built from the path the camera reports in
/// its `photo_taken` notification. Auto-dismisses so it does not sit over the
/// viewfinder.
struct CapturePreview: View {
    let path: String

    @State private var image: UIImage?
    @State private var visible = false

    var body: some View {
        Group {
            if let image, visible {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // Constrain the long edge and let the short edge follow the
                    // image's real ratio, so a 4:3 still is not cropped square.
                    .frame(maxWidth: 96, maxHeight: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                    )
                    .shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Last photo captured")
            }
        }
        .animation(.spring(duration: 0.3), value: visible)
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        visible = false

        // The notification gives a camera-side absolute path; the model owns
        // the mapping to the HTTP file server.
        guard let url = YiFile.httpURL(forCameraPath: path) else { return }

        // The camera needs a moment to finish writing the file.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }

        guard let data = await ThumbnailLoader.fetch(url, timeout: 15),
              let decoded = ThumbnailLoader.downsampled(data) else { return }

        image = decoded
        visible = true

        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        visible = false
    }
}

/// Async thumbnail with a placeholder, sized for the gallery grid.
struct ThumbnailView: View {
    let file: YiFile

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false

    /// The camera shoots 4:3 stills (4608x3456) and 16:9 video, so a square
    /// frame would letterbox the placeholder and crop the loaded image — the
    /// cell would visibly change shape once the thumbnail arrived. The frame
    /// matches the media's real aspect ratio from the start, and once a
    /// thumbnail loads its own dimensions take over so an unexpected ratio
    /// still renders uncropped.
    private var aspectRatio: CGFloat {
        if let image, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return file.isVideo ? 16.0 / 9.0 : 4.0 / 3.0
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.tertiarySystemGroupedBackground))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    // .fit, not .fill: the frame already matches the image's
                    // ratio, so filling would crop for no reason.
                    .scaledToFit()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundStyle(.gray.opacity(0.5))
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: image != nil)
        .task(id: file.path) { await load() }
    }

    /// Videos have no preview, so the icon is the final state, not a fallback.
    private var icon: String {
        if file.isVideo { return "video.fill" }
        return failed ? "photo.badge.exclamationmark" : "photo.fill"
    }

    private func load() async {
        if let hit = ThumbnailLoader.shared.cached(for: file) {
            image = hit
            return
        }

        isLoading = true
        defer { isLoading = false }

        // The loader handles the sidecar-then-original fallback internally.
        let result = await ThumbnailLoader.shared.thumbnail(for: file)
        image = result
        failed = (result == nil)
    }
}
