import Foundation

/// Lists directories on the camera's Linux filesystem.
///
/// `1282` lists any path, not just `DCIM`, so the whole root is reachable.
/// `DirectoryBrowserView` drives this one level per tap — one request per
/// navigation, which is what keeps a fragile control channel quiet.
///
/// **`.` and `..` are dropped**, so a caller that follows entries cannot walk
/// in a circle.
@MainActor
final class FilesystemExplorer {

    struct Entry: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let name: String
        /// Best guess, combining the explicit marker with a size heuristic.
        let isDirectory: Bool
        /// The camera named this entry with a trailing `/`. Unlike
        /// `isDirectory` this is the firmware's own statement, not inference,
        /// so it is safe to gate destructive or download actions on.
        var isMarkedDirectory: Bool = false
        let size: Int64
        let depth: Int

        private var fileExtension: String {
            (name as NSString).pathExtension.lowercased()
        }

        var isImage: Bool {
            ["jpg", "jpeg", "png", "bmp", "gif", "thm"].contains(fileExtension)
        }

        /// Whether the photo library would plausibly accept this file.
        var isMedia: Bool {
            isImage || ["mp4", "mov", "avi"].contains(fileExtension)
        }
    }

    /// Generous: the camera can take seconds over a large directory, and a
    /// premature timeout leaves a request in flight on a channel that must
    /// carry exactly one at a time.
    private static let listTimeout: Duration = .seconds(8)

    private let client: YiCameraClient

    init(client: YiCameraClient) {
        self.client = client
    }


    /// Lists a single directory, throwing on failure.
    ///
    /// Throwing rather than returning `[]` and logging keeps the error contract
    /// in the type system: callers that surface errors to the user cannot
    /// silently break when a log message is reworded.
    func list(directory: String, depth: Int) async throws -> [Entry] {
        let response = try await client.sendRaw(
            msgId: YiCommand.listDirectory.rawValue,
            param: "-D -S \(directory)",
            timeout: Self.listTimeout
        )

        let rval = response.rval
        guard rval == YiReturnCode.success else {
            throw YiCameraError.commandFailed(msgId: YiCommand.listDirectory.rawValue, rval: rval)
        }
        guard let listing = response["listing"] as? [[String: Any]] else { return [] }

        return listing.flatMap { entry in
            entry.compactMap { name, value -> Entry? in
                // `.` and `..` would immediately cycle the walk.
                guard name != ".", name != ".." else { return nil }

                let (size, inferredDirectory) = Self.describe(value)
                // A trailing slash on the name is this firmware's explicit
                // directory marker, and is far more reliable than inferring
                // from the size — a Linux directory reports a real block size
                // that is indistinguishable from a file's.
                let markedDirectory = name.hasSuffix("/")
                let displayName = markedDirectory ? String(name.dropLast()) : name

                // **Keep the trailing slash in the path.** Listing `/tmp`
                // without it kills the camera's TCP server outright, while
                // `/tmp/` lists fine — verified against a browse that worked
                // before the slash was stripped. The name is trimmed for
                // display only; the path is what goes back to the camera.
                let childPath = join(directory, name)
                return Entry(path: childPath,
                             name: displayName,
                             isDirectory: markedDirectory || inferredDirectory,
                             isMarkedDirectory: markedDirectory,
                             size: size,
                             depth: depth)
            }
        }
    }

    /// Interprets a listing value.
    ///
    /// Files carry `"<size> bytes|<date>"`. Directories are reported
    /// inconsistently across firmwares — as an empty string, a nested
    /// container, or a value with no byte count — so anything that does not
    /// parse as a sized file is treated as a directory.
    static func describe(_ value: Any) -> (size: Int64, isDirectory: Bool) {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return (0, true) }
            // No parsable byte count means this is not a sized file.
            guard let size = YiFileManager.parseSize(trimmed) else {
                return (0, true)
            }
            // A Linux directory inode typically reports a block-sized length
            // (4096, or a multiple of it) rather than 0. Treat those as
            // directories so the icon is a useful hint — but note this is only
            // a heuristic, which is exactly why navigation never depends on it.
            if size == 0 || (size % 4096 == 0 && size <= 65536) {
                return (size, true)
            }
            return (size, false)
        }
        // Nested containers only ever represent directories.
        return (0, true)
    }

    /// Joins with exactly one separator.
    ///
    /// A directory that already ends in `/` — which the camera's own listings
    /// report — would otherwise produce `/tmp//fuse_z`. The camera tolerates
    /// that when listing a directory but rejects it when probing a file.
    private func join(_ directory: String, _ name: String) -> String {
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let leaf = name.hasPrefix("/") ? String(name.dropFirst()) : name
        return "\(base)/\(leaf)"
    }

}
