import Foundation

struct YiFile: Identifiable, Hashable {
    /// The camera path is unique per file, so it makes a stable identity —
    /// unlike a fresh UUID, which would churn the list on every refresh.
    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    let date: Date?

    /// The camera writes a preview file beside every capture, in one of two
    /// forms depending on the media type:
    ///
    ///  - photos get a JPEG:  `YDXJ0183.jpg` → `YDXJ0183.THM`
    ///  - videos get a short clip: `YDXJ0182.mp4` → `YDXJ0182_thm.mp4`
    ///
    /// Both are listed as ordinary directory entries, so both must be hidden
    /// from the gallery — a `_thm.mp4` would otherwise appear as a second,
    /// tiny video next to every real one.
    var isThumbnail: Bool {
        let stem = (name as NSString).deletingPathExtension
        return (name as NSString).pathExtension.caseInsensitiveCompare("thm") == .orderedSame
            || stem.lowercased().hasSuffix("_thm")
    }

    /// Path of this file's preview sidecar, if it has one.
    var thumbnailPath: String? {
        guard !isThumbnail else { return nil }
        let stem = (path as NSString).deletingPathExtension
        // Video previews keep the container extension; photo previews are .THM.
        return isVideo ? "\(stem)_thm.\((path as NSString).pathExtension)" : "\(stem).THM"
    }

    var isVideo: Bool {
        Self.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "avi"]

    /// Media is served over plain HTTP, rooted at the SD card mount point.
    var downloadURL: URL? {
        Self.httpURL(forCameraPath: path)
    }

    /// URL of the preview sidecar, used for gallery thumbnails.
    var thumbnailURL: URL? {
        thumbnailPath.flatMap(Self.httpURL(forCameraPath:))
    }

    /// Whether the preview sidecar is itself a video, and so needs a frame
    /// extracted rather than being decodable as an image.
    var thumbnailIsVideo: Bool { isVideo }

    static func httpURL(forCameraPath path: String) -> URL? {
        let relative = path.replacingOccurrences(of: YiFileManager.mediaRoot, with: "")
        let escaped = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        return URL(string: "http://192.168.42.1/\(escaped)")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Bridges `URLSessionTask.progress` to a callback for the async download API,
/// which otherwise reports nothing until the transfer completes.
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }

    deinit { observation?.invalidate() }
}

extension URLSession {
    /// `download(from:)` with progress reporting.
    func download(from url: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        try await download(for: URLRequest(url: url),
                           delegate: DownloadProgressDelegate(onProgress: progress))
    }
}

@MainActor
class YiFileManager: ObservableObject {

    /// Everything on the SD card lives under the FUSE mount.
    /// `nonisolated` because `YiFile` (a plain value type) reads these while
    /// building paths and URLs off the actor.
    nonisolated static let mediaRoot = "/tmp/fuse_d/"
    nonisolated static let mediaDirectory = "/tmp/fuse_d/DCIM/100MEDIA"

    @Published private(set) var files: [YiFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var downloadingFile: YiFile?
    @Published private(set) var downloadProgress: Double = 0
    @Published var errorMessage: String?
    /// Set after a successful save so the UI can confirm where the file went.
    @Published var savedMessage: String?

    private let client: YiCameraClient
    private var downloadTask: Task<Void, Never>?

    init(client: YiCameraClient) {
        self.client = client
    }

    // MARK: - Listing

    func listFiles() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // -D -S asks for details and sizes.
            let response = try await client.sendRaw(
                msgId: YiCommand.listDirectory.rawValue,
                param: "-D -S \(Self.mediaDirectory)",
                timeout: .seconds(15) // Large cards take a while to enumerate.
            )

            let rval = response.rval

            // An empty or unformatted card is a normal state, not an error.
            if rval == -26 {
                files = []
                return
            }
            guard rval == YiReturnCode.success else {
                throw YiCameraError.commandFailed(msgId: YiCommand.listDirectory.rawValue, rval: rval)
            }

            guard let listing = response["listing"] as? [[String: Any]] else {
                files = []
                return
            }

            // The camera lists a .THM sidecar next to every media file. Those
            // are previews, not media — showing them would double the gallery
            // and fill it with tiny duplicate entries.
            files = Self.parse(listing: listing)
                .filter { !$0.isThumbnail }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        } catch {
            errorMessage = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Parses an Ambarella directory listing.
    ///
    /// The camera returns the **filename as the JSON key** and packs metadata
    /// into the value, e.g.
    /// `{"YDXJ1155.mp4": "391922457 bytes|2015-05-25 14:35:18"}`.
    /// There is no `name`/`size` key to read.
    ///
    /// A few firmwares instead return a dictionary per entry, so both shapes
    /// are accepted.
    static func parse(listing: [[String: Any]]) -> [YiFile] {
        var result: [YiFile] = []

        for entry in listing {
            for (key, value) in entry {
                if let meta = value as? String {
                    let (size, date) = parseMetadata(meta)
                    result.append(YiFile(name: key,
                                         path: "\(mediaDirectory)/\(key)",
                                         size: size,
                                         date: date))
                } else if let fields = value as? [String: Any],
                          let name = fields["name"] as? String {
                    // Alternate shape: {"<dir>": {"name": ..., "size": ...}}
                    result.append(YiFile(name: name,
                                         path: "\(mediaDirectory)/\(name)",
                                         size: Int64(YiCameraClient.intValue(fields["size"]) ?? 0),
                                         date: (fields["date"] as? String).flatMap(parseDate)))
                } else if let items = value as? [[String: Any]] {
                    // Alternate shape: {"<dir>": [{"name": ..., "size": ...}, …]}
                    for item in items {
                        guard let name = item["name"] as? String else { continue }
                        result.append(YiFile(name: name,
                                             path: "\(mediaDirectory)/\(name)",
                                             size: Int64(YiCameraClient.intValue(item["size"]) ?? 0),
                                             date: (item["date"] as? String).flatMap(parseDate)))
                    }
                }
            }
        }
        return result
    }

    /// Parses the size out of a listing value such as
    /// `"391922457 bytes|2015-05-25 14:35:18"`. Returns `nil` when the value
    /// carries no byte count, which is how directories are reported.
    nonisolated static func parseSize(_ raw: String) -> Int64? {
        guard let sizeText = raw.components(separatedBy: "|").first?
            .replacingOccurrences(of: "bytes", with: "")
            .trimmingCharacters(in: .whitespaces) else { return nil }
        return Int64(sizeText)
    }

    /// Splits `"391922457 bytes|2015-05-25 14:35:18"` into its parts.
    private static func parseMetadata(_ raw: String) -> (size: Int64, date: Date?) {
        let parts = raw.components(separatedBy: "|")
        let date = parts.count > 1 ? parseDate(parts[1]) : nil
        return (parseSize(raw) ?? 0, date)
    }

    private static func parseDate(_ raw: String) -> Date? {
        // The camera speaks local wall-clock time in one format; the client
        // owns that formatter since it also writes the camera's clock.
        YiCameraClient.clockFormatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Mutation

    func deleteFile(_ file: YiFile) async {
        do {
            _ = try await client.send(.deleteFile, param: file.path)

            // Remove the .THM sidecar too, or the card fills with orphaned
            // thumbnails for media that no longer exists. Best-effort: the
            // media file is already gone, so a missing sidecar is not a
            // failure worth surfacing.
            if let thumbnailPath = file.thumbnailPath {
                _ = try? await client.send(.deleteFile, param: thumbnailPath)
            }

            files.removeAll { $0.id == file.id }
            // The camera reuses filenames, so a stale cached preview would
            // otherwise show up against a different file later.
            ThumbnailLoader.shared.invalidate(file)
        } catch {
            errorMessage = (error as? YiCameraError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Download

    func downloadFile(_ file: YiFile) {
        guard downloadingFile == nil, let url = file.downloadURL else { return }

        downloadingFile = file
        downloadProgress = 0

        downloadTask = Task { [weak self] in
            defer {
                self?.downloadingFile = nil
                self?.downloadProgress = 0
            }
            do {
                // Ask before spending time on a download we cannot save.
                guard await PhotoLibrarySaver.requestAccess() else {
                    self?.errorMessage = PhotoLibrarySaver.SaveError.permissionDenied.errorDescription
                    return
                }

                let downloaded = try await Self.download(from: url, named: file.name) { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress }
                }

                // Save completes before the staged file is removed — Photos
                // copies from this URL, so deleting it early loses the asset.
                do {
                    try await PhotoLibrarySaver.save(fileURL: downloaded, isVideo: file.isVideo)
                    try? FileManager.default.removeItem(at: downloaded)
                } catch {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw error
                }
                self?.savedMessage = "\(file.name) saved to Photos"
            } catch is CancellationError {
                // User cancelled; nothing to report.
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Downloads straight to disk, so large videos never sit in memory.
    ///
    /// `URLSession.download` writes to its own temporary file and reports
    /// progress through the task, which avoids reading the body byte by byte —
    /// a several-hundred-megabyte video would otherwise cost one async
    /// iteration and one single-byte append per byte.
    private static func download(from url: URL, named name: String,
                                 onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(
            from: url, progress: onProgress
        )

        do {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            // Staged in the temporary directory: Photos copies the file into
            // the library, after which the caller deletes this. Writing to
            // Documents would leave media in the app's private container,
            // where it is invisible to the user and never reclaimed.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("yippy-download", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            // Photos infers the asset type from the file extension, so keep it.
            let destination = staging.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloaded, to: destination)
            onProgress(1)
            return destination
        } catch {
            // URLSession hands us ownership of the temporary file; it is not
            // cleaned up for us if we bail out before moving it.
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
    }
}
