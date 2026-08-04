import Foundation

/// Immutable slice of the filesystem tree produced by a scan.
/// Children are pruned to the largest entries; the difference between `size`
/// and the sum of children is "everything smaller" and is recomputed in UI.
public struct FileNode: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    /// Allocated bytes (st_blocks * 512) — what deleting would actually free.
    public let size: Int64
    public let isDirectory: Bool
    /// True for bundles shown as leaves (.app, .photoslibrary, …).
    public let isPackage: Bool
    /// Newest mtime anywhere inside (the folder's own mtime for empty ones).
    /// "12 GB" is a fact; "12 GB, untouched since March" is a decision.
    public let modified: Date
    public var children: [FileNode]

    public init(
        name: String,
        path: String,
        size: Int64,
        isDirectory: Bool,
        isPackage: Bool = false,
        modified: Date = .distantPast,
        children: [FileNode] = []
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modified = modified
        self.children = children
    }

    /// Bytes not represented by (pruned) children.
    public var remainder: Int64 {
        max(0, size - children.reduce(0) { $0 + $1.size })
    }
}

public struct LargeFile: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}
