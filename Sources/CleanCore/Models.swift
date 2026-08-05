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

/// A finished scan. Everything derived from the item list is computed once,
/// here, because the alternative was computing it inside SwiftUI bodies: the
/// Deep Clean screen walked the whole array six times to decide which category
/// headers to show, then once more per header, then again for the totals — all
/// of it repeated on every single render.
public struct ScanReport: Sendable {
    public let items: [CleanItem]
    public let totalBytes: Int64
    private let byCategory: [CleanCategory: [CleanItem]]
    private let byID: [String: CleanItem]

    public func items(in category: CleanCategory) -> [CleanItem] {
        byCategory[category] ?? []
    }

    /// Categories that actually found something, in catalog order.
    public var populatedCategories: [CleanCategory] {
        CleanCategory.allCases.filter { byCategory[$0] != nil }
    }

    /// Looking items up by id beats filtering the array for each one; the
    /// selection can hold thousands of ids.
    public func item(id: String) -> CleanItem? { byID[id] }

    public func bytes(of ids: Set<String>) -> Int64 {
        ids.reduce(0) { $0 + (byID[$1]?.size ?? 0) }
    }

    public func items(ids: Set<String>) -> [CleanItem] {
        items.filter { ids.contains($0.id) }
    }

    public init(items: [CleanItem] = []) {
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.size }
        self.byCategory = Dictionary(grouping: items, by: \.category)
        // The scanner dedupes by path, and id *is* the path — but a crash here
        // would be a poor way to find out if that ever stopped being true.
        self.byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
