import Foundation
import Darwin

/// Folders the user marked as untouchable.
///
/// The list is enforced inside `SafetyPolicy.validate`, not in a view: the CLI,
/// the headless weekly clean and any future feature all funnel through that one
/// chokepoint, and a check that lived in the UI would simply be bypassed.
///
/// Storage is a plain text file the user can open, read and edit by hand
/// (~/Library/Application Support/Chinchilla/exclusions.txt), one path per
/// line, `#` comments and blank lines ignored, `~` expanded.
public enum UserExclusions {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { raw }
        /// Exactly what the file says — written back verbatim on removal.
        public let raw: String
        /// Tilde-expanded, for display and for the "is it still there?" check.
        public let path: String
        /// Symlinks resolved, for matching. Both sides of the comparison are
        /// resolved so a symlinked route can't sneak around an exclusion.
        public let resolved: String
    }

    public static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Chinchilla/exclusions.txt")
    }

    // MARK: - Cache
    //
    // `validate` runs once per candidate path — hundreds of thousands in a big
    // scan — so this must never stat the file per call. The parsed list lives in
    // memory; we only re-stat after `stalenessWindow` has passed, and writes
    // through `add`/`remove` invalidate immediately. Worst case a hand edit of
    // the file takes two seconds to be noticed.

    private static let lock = NSLock()
    private static let stalenessWindow: UInt64 = 2_000_000_000  // nanoseconds

    nonisolated(unsafe) private static var cached: [Entry] = []
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var lastCheck: UInt64 = 0
    nonisolated(unsafe) private static var lastStamp: Stamp?
    nonisolated(unsafe) private static var overrideURL: URL?

    private struct Stamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
        let size: Int64
        let inode: UInt64
    }

    public static var fileURL: URL {
        lock.withLock { overrideURL ?? defaultFileURL }
    }

    /// Current entries, newest last. Cheap — served from the cache.
    public static func entries() -> [Entry] {
        lock.withLock {
            refreshIfNeeded()
            return cached
        }
    }

    /// The entry protecting `resolvedPath`, if any. `resolvedPath` must already
    /// have gone through `SafetyPolicy.resolve`.
    static func match(resolvedPath: String) -> Entry? {
        lock.withLock {
            refreshIfNeeded()
            // Common case is an empty list; `first(where:)` on an empty array is
            // already free, so no extra fast path is needed.
            return cached.first { resolvedPath.isUnder($0.resolved) }
        }
    }

    /// True if the user has protected this path (or a folder containing it).
    public static func isExcluded(_ path: String) -> Bool {
        match(resolvedPath: SafetyPolicy.resolve(path)) != nil
    }

    // MARK: - Editing

    public static func add(_ path: String) throws {
        let line = normalizeForStorage(path)
        guard !line.isEmpty else { return }
        try lock.withLock {
            let url = overrideURL ?? defaultFileURL
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? defaultHeader
            if text.isEmpty || text.hasSuffix("\n") == false { text += "\n" }
            // Editing by hand and via the UI must not produce duplicates.
            let already = text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.trimmingCharacters(in: .whitespaces) == line }
            if !already { text += line + "\n" }
            try write(text, to: url)
            invalidate()
        }
    }

    public static func remove(_ entry: Entry) throws {
        try lock.withLock {
            let url = overrideURL ?? defaultFileURL
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces) != entry.raw }
            try write(kept.joined(separator: "\n"), to: url)
            invalidate()
        }
    }

    /// Drops the cache; the next read re-parses the file.
    public static func reload() {
        lock.withLock { invalidate() }
    }

    // MARK: - Internals (call with `lock` held)

    private static func invalidate() {
        loaded = false
        lastStamp = nil
        lastCheck = 0
    }

    private static func refreshIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        if loaded, now &- lastCheck < stalenessWindow { return }
        lastCheck = now

        let url = overrideURL ?? defaultFileURL
        let stamp = stampOf(url.path)
        if loaded, stamp == lastStamp { return }
        lastStamp = stamp
        cached = parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        loaded = true
    }

    private static func stampOf(_ path: String) -> Stamp? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Stamp(
            seconds: st.st_mtimespec.tv_sec,
            nanoseconds: st.st_mtimespec.tv_nsec,
            size: st.st_size,
            inode: st.st_ino
        )
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let expanded = (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            // Trailing slashes would break the `isUnder` prefix comparison.
            let path = expanded.count > 1 && expanded.hasSuffix("/")
                ? String(expanded.dropLast()) : expanded
            guard seen.insert(path).inserted else { continue }
            entries.append(Entry(raw: raw, path: path, resolved: SafetyPolicy.resolve(path)))
        }
        return entries
    }

    /// Keeps the home directory as `~` so the file stays readable and survives
    /// a rename of the account's home folder.
    private static func normalizeForStorage(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return trimmed }
        return (trimmed as NSString).abbreviatingWithTildeInPath
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let defaultHeader = """
        # Chinchilla — folders you never want touched.
        # One path per line. Lines starting with # are ignored. ~ means your home folder.

        """

    // MARK: - Test hook

    /// Redirects the store to a scratch file. Tests only — the suite that uses
    /// it is `.serialized` because this is process-global state.
    static func useFile(_ url: URL?) {
        lock.withLock {
            overrideURL = url
            invalidate()
        }
    }
}
