import Foundation

/// Debug tool that walks the camera's Linux filesystem breadth-first.
///
/// The traversal is **breadth-first by depth level**, not a recursive descent:
/// it lists every directory at depth N before any at depth N+1. That makes the
/// cost of each additional level explicit and lets the walk stop at a useful
/// depth instead of disappearing down one deep branch.
///
/// **Nothing is excluded by path.** `/proc`, `/sys` and `/dev` are synthetic and
/// can be very large, and enumerating them may stress the firmware's TCP
/// server — but they are walked like anything else. The depth limit and the
/// entry/level caps are what bound the work.
///
/// Two guards remain, because without them the walk cannot terminate at all:
/// every visited path is recorded (symlinks form cycles such as `/a/b -> /a`),
/// and `.`/`..` are dropped.
@MainActor
final class FilesystemExplorer: ObservableObject {

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

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""

    /// Hard ceilings so a pathological filesystem cannot run forever.
    ///
    /// Nothing is excluded by path — `/proc`, `/sys` and `/dev` are walked like
    /// anything else. They are synthetic and can be very large, so these caps
    /// (and the depth limit) are the only thing bounding the walk.
    private static let maxEntries = 20000
    private static let maxDirectoriesPerLevel = 2000
    private static let listTimeout: Duration = .seconds(8)
    /// The camera's TCP server is fragile; pace the requests.
    private static let interRequestDelay: Duration = .milliseconds(120)

    private let client: YiCameraClient
    private var task: Task<Void, Never>?

    init(client: YiCameraClient) {
        self.client = client
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        progress = ""
        note("Cancelled.")
    }

    /// Walks the filesystem from `root` down to `maxDepth` levels.
    func explore(root: String = "/", maxDepth: Int = 3) {
        guard !isRunning else { return }
        isRunning = true
        entries = []
        log = []

        task = Task {
            defer { isRunning = false; progress = "" }

            note("Walking \(root) to depth \(maxDepth) (breadth-first).")
            note("No paths excluded — /proc, /sys and /dev are included.")

            // `visited` guards against symlink cycles: a path is listed at most
            // once no matter how many routes lead back to it.
            var visited: Set<String> = []
            var frontier: [String] = [root]
            visited.insert(normalise(root))

            for depth in 0...maxDepth {
                if Task.isCancelled || frontier.isEmpty { break }
                guard client.isConnected else {
                    note("Aborted: camera disconnected.")
                    break
                }
                guard entries.count < Self.maxEntries else {
                    note("Stopped: reached the \(Self.maxEntries)-entry cap.")
                    break
                }

                note("── depth \(depth): \(frontier.count) director\(frontier.count == 1 ? "y" : "ies")")

                var next: [String] = []
                for (index, directory) in frontier.enumerated() {
                    if Task.isCancelled { break }
                    progress = "Depth \(depth) — \(index + 1)/\(frontier.count): \(directory)"

                    let children = await listIgnoringErrors(directory: directory, depth: depth)

                    for child in children {
                        entries.append(child)
                        guard child.isDirectory, depth < maxDepth else { continue }

                        let key = normalise(child.path)
                        // Cycle guard. Not a filter — without it a symlink loop
                        // (/a/b -> /a) never terminates.
                        guard !visited.contains(key) else {
                            note("↩︎ already visited: \(child.path)")
                            continue
                        }
                        visited.insert(key)
                        next.append(child.path)
                    }

                    try? await Task.sleep(for: Self.interRequestDelay)
                }

                if next.count > Self.maxDirectoriesPerLevel {
                    note("⚠︎ depth \(depth + 1) had \(next.count) directories; truncated to \(Self.maxDirectoriesPerLevel).")
                    next = Array(next.prefix(Self.maxDirectoriesPerLevel))
                }
                frontier = next
            }

            let dirs = entries.filter(\.isDirectory).count
            note("Done. \(entries.count) entries (\(dirs) directories, \(entries.count - dirs) files).")
        }
    }

    /// Lists a single directory, swallowing errors — a permission error or
    /// unreadable node must not stop the whole walk. Use `list(directory:)`
    /// when the caller needs to report the failure.
    private func listIgnoringErrors(directory: String, depth: Int) async -> [Entry] {
        do {
            return try await list(directory: directory, depth: depth)
        } catch {
            note("✗ \(directory): \(error.localizedDescription)")
            return []
        }
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

    /// Collapses trailing slashes so `/tmp` and `/tmp/` cannot both be visited.
    private func normalise(_ path: String) -> String {
        path == "/" ? path : String(path.reversed().drop { $0 == "/" }.reversed())
    }

    private func note(_ message: String) {
        log.append(message)
        print("[fs] \(message)")
    }
}
