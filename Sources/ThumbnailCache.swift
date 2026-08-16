import UIKit

/// On-disk thumbnail cache, partitioned per camera.
///
/// Thumbnails are expensive on this link — every one is an HTTP fetch over the
/// camera's slow Wi-Fi, and for videos it also means downloading a sidecar clip
/// and decoding a frame. Persisting them means the gallery is populated on the
/// next launch without touching the camera at all.
///
/// **Keyed by camera, not just filename.** The camera restarts numbering at
/// `YDXJ0001` on every fresh card, so a cache keyed by filename alone would
/// serve one camera's thumbnail for a different camera's file. Each camera gets
/// its own subdirectory.
///
/// The entry key also folds in size and timestamp, so a recycled filename with
/// different content misses rather than showing the previous file's image.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    /// Bounds the cache so it cannot grow without limit across many cards.
    private static let maxBytes: Int64 = 128 * 1024 * 1024

    private let root: URL
    /// Running byte total, measured once then maintained incrementally.
    private var totalBytes: Int64?
    /// Partitions whose directory has already been created this session.
    private var preparedPartitions: Set<String> = []

    private init() {
        // Caches, not Documents: the system may reclaim this under storage
        // pressure, which is correct for regenerable data.
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    // MARK: - Keys

    /// Identity of a cached entry: the filename plus the attributes that change
    /// when the content does.
    private nonisolated func entryName(for file: YiFile) -> String {
        let stem = (file.name as NSString).deletingPathExtension
        let stamp = file.date.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(stem)-\(file.size)-\(stamp).jpg"
    }

    private func directory(for cameraID: String) -> URL {
        root.appendingPathComponent(cameraID, isDirectory: true)
    }

    private func location(cameraID: String, file: YiFile) -> URL {
        directory(for: cameraID).appendingPathComponent(entryName(for: file))
    }

    // MARK: - Access

    func image(for file: YiFile, cameraID: String) -> UIImage? {
        let url = location(cameraID: cameraID, file: file)
        // No modification-date touch on read: that is a filesystem *write* per
        // cache hit, so scrolling a gallery would mutate metadata once per
        // visible cell. Eviction falls back to write order, which is fine for a
        // bounded, regenerable cache.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    func store(_ image: UIImage, for file: YiFile, cameraID: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }

        // Creating the directory is only needed once per camera.
        if !preparedPartitions.contains(cameraID) {
            try? FileManager.default.createDirectory(at: directory(for: cameraID),
                                                     withIntermediateDirectories: true)
            preparedPartitions.insert(cameraID)
        }

        let url = location(cameraID: cameraID, file: file)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        // Track the total so the size limit does not need a full-tree sweep to
        // discover the cache is under budget.
        if let known = totalBytes { totalBytes = known + Int64(data.count) }
    }

    /// Stores an image under an arbitrary name rather than a `YiFile`, for
    /// per-camera artwork such as the device logo.
    func image(named name: String, cameraID: String) -> UIImage? {
        let url = directory(for: cameraID).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return UIImage(data: data)
    }

    func store(_ image: UIImage, named name: String, cameraID: String) {
        guard let data = image.pngData() else { return }
        if !preparedPartitions.contains(cameraID) {
            try? FileManager.default.createDirectory(at: directory(for: cameraID),
                                                     withIntermediateDirectories: true)
            preparedPartitions.insert(cameraID)
        }
        let url = directory(for: cameraID).appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        if let known = totalBytes { totalBytes = known + Int64(data.count) }
    }

    /// Drops a single entry — used when its file is deleted from the camera.
    func remove(_ file: YiFile, cameraID: String) {
        let url = location(cameraID: cameraID, file: file)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        try? FileManager.default.removeItem(at: url)
        if let known = totalBytes, let size { totalBytes = max(0, known - Int64(size)) }
    }

    // MARK: - Eviction

    /// Removes entries for files that are no longer on the camera.
    ///
    /// Call once the gallery listing is known to be complete: anything cached
    /// for this camera that is not in `files` refers to media that has since
    /// been deleted, on the camera or elsewhere.
    func evictEntriesNotIn(_ files: [YiFile], cameraID: String) {
        let directory = directory(for: cameraID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let live = Set(files.map { entryName(for: $0) })
        for entry in entries where !live.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Trims the cache only when the running total says it is over budget.
    ///
    /// The full sweep is a recursive enumeration plus a stat per entry, so it
    /// must not run on every listing — it is called after each refresh, which
    /// includes every capture.
    func enforceSizeLimitIfNeeded() {
        if totalBytes == nil { totalBytes = measureTotal() }
        guard let total = totalBytes, total > Self.maxBytes else { return }
        enforceSizeLimit()
    }

    private func measureTotal() -> Int64 {
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        )?.compactMap({ $0 as? URL }) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
    }

    /// Trims the whole cache to `maxBytes`, oldest first.
    private func enforceSizeLimit() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys
        )?.compactMap({ $0 as? URL }) else { return }

        var sized: [(url: URL, date: Date, size: Int64)] = []
        var total: Int64 = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            let date = values.contentModificationDate ?? .distantPast
            sized.append((url, date, Int64(size)))
            total += Int64(size)
        }

        defer { totalBytes = total }
        guard total > Self.maxBytes else { return }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= Self.maxBytes { return }
        }
    }
}
