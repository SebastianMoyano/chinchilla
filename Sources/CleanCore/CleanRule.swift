import Foundation

/// How to treat `com.apple.*` bundle-id directories found by a rule.
public enum AppleBundlePolicy: Sendable {
    /// Skip Apple bundle IDs unless explicitly allowlisted (default for caches).
    case skipUnlessAllowlisted(Set<String>)
    /// No special handling.
    case include
}

public struct CleanRule: Sendable, Identifiable {
    public let id: String
    public let category: CleanCategory
    /// English display key (localized via Localizable.strings).
    public let title: String
    /// Glob patterns; `~` expands to home, `*` matches one path component.
    public let patterns: [String]
    public let safety: Safety
    public let deleteMode: DeleteMode
    /// Skip matches modified more recently than this many hours (in-use guard).
    public let minAgeHours: Double
    public let requiresFullDiskAccess: Bool
    /// Delete contents of each match rather than the match itself.
    public let contentsOnly: Bool
    /// Match names to skip entirely.
    public let skipNames: Set<String>
    /// File extensions filter (lowercased, no dot); empty = all.
    public let extensions: Set<String>
    public let applePolicy: AppleBundlePolicy
    /// Bundle IDs whose apps should be quit before cleaning these items.
    public let conflictingBundleIDs: [String]

    public init(
        id: String,
        category: CleanCategory,
        title: String,
        patterns: [String],
        safety: Safety,
        deleteMode: DeleteMode = .unlink,
        minAgeHours: Double = 24,
        requiresFullDiskAccess: Bool = false,
        contentsOnly: Bool = false,
        skipNames: Set<String> = [],
        extensions: Set<String> = [],
        applePolicy: AppleBundlePolicy = .include,
        conflictingBundleIDs: [String] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.patterns = patterns
        self.safety = safety
        self.deleteMode = deleteMode
        self.minAgeHours = minAgeHours
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.contentsOnly = contentsOnly
        self.skipNames = skipNames
        self.extensions = extensions
        self.applePolicy = applePolicy
        self.conflictingBundleIDs = conflictingBundleIDs
    }

    /// Directory roots this rule may delete under — used by SafetyPolicy.
    public var declaredRoots: [String] {
        patterns.map { pattern in
            let expanded = (pattern as NSString).expandingTildeInPath
            // Root = everything before the first glob component.
            let components = (expanded as NSString).pathComponents
            var root = ""
            for component in components {
                if component.contains("*") { break }
                root = (root as NSString).appendingPathComponent(component)
            }
            return root
        }
    }
}
