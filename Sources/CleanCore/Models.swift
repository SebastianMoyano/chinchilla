import Foundation

public enum Safety: String, Sendable, Codable, Comparable {
    case safe
    case moderate
    case caution

    private var rank: Int {
        switch self {
        case .safe: 0
        case .moderate: 1
        case .caution: 2
        }
    }

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rank < rhs.rank }
}

public enum DeleteMode: String, Sendable, Codable {
    /// Recoverable: FileManager.trashItem.
    case trash
    /// Immediate unlink — for caches, where trashing just moves bytes.
    case unlink
}

public enum CleanCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case userCaches
    case browsers
    case logs
    case installers
    case trash
    case developer

    public var id: String { rawValue }
}

/// One cleanable filesystem entry found by a scan.
public struct CleanItem: Sendable, Identifiable, Hashable, Codable {
    public var id: String { path }
    public let ruleID: String
    public let category: CleanCategory
    public let path: String
    public let size: Int64
    public let modified: Date
    public let safety: Safety
    public let deleteMode: DeleteMode
    /// Delete the contents of `path` but keep the directory itself
    /// (preserves permissions apps expect on their cache dir).
    public let contentsOnly: Bool

    public init(
        ruleID: String, category: CleanCategory, path: String, size: Int64,
        modified: Date, safety: Safety, deleteMode: DeleteMode, contentsOnly: Bool
    ) {
        self.ruleID = ruleID
        self.category = category
        self.path = path
        self.size = size
        self.modified = modified
        self.safety = safety
        self.deleteMode = deleteMode
        self.contentsOnly = contentsOnly
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct ScanReport: Sendable {
    public var items: [CleanItem] = []
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    public func items(in category: CleanCategory) -> [CleanItem] {
        items.filter { $0.category == category }
    }

    public init(items: [CleanItem] = []) {
        self.items = items
    }
}
