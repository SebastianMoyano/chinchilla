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
    /// A trailing `*` matches by prefix — Adobe puts the year in theirs.
    public let conflictingBundleIDs: [String]
    /// Process names (as `proc_name` reports them) that use these items while
    /// alive: command-line tools and daemons have no bundle ID to watch.
    public let conflictingProcessNames: [String]
    /// For directory matches: keep the folder unless it is at least
    /// `minAgeHours` old and no file in it changed after it was created —
    /// anything edited after the fact is the user's work, not a copy.
    public let untouchedOnly: Bool
    /// Size items by what deleting them frees, not what they occupy: for
    /// caches that installs clone out of (APFS shares the blocks).
    public let sizeByReclaimable: Bool
    /// The tree is made read-only by its owner (Go's module cache); grant
    /// ourselves write permission on its folders before removing it.
    public let unlockReadOnlyTree: Bool
    /// Symlinks whose targets must stay (e.g. the CLI's current version).
    public let keepTargetsOf: [String]
    /// Skip matches that are, or contain, a running program's executable.
    public let keepRunningExecutables: Bool

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
        conflictingBundleIDs: [String] = [],
        conflictingProcessNames: [String] = [],
        untouchedOnly: Bool = false,
        sizeByReclaimable: Bool = false,
        unlockReadOnlyTree: Bool = false,
        keepTargetsOf: [String] = [],
        keepRunningExecutables: Bool = false
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
        self.conflictingProcessNames = conflictingProcessNames
        self.untouchedOnly = untouchedOnly
        self.sizeByReclaimable = sizeByReclaimable
        self.unlockReadOnlyTree = unlockReadOnlyTree
        self.keepTargetsOf = keepTargetsOf
        self.keepRunningExecutables = keepRunningExecutables
    }

    /// True while an app or tool that uses this rule's items is running.
    public func conflicts(
        runningBundleIDs: Set<String>, runningProcessNames: Set<String>
    ) -> Bool {
        if conflictingProcessNames.contains(where: runningProcessNames.contains) { return true }
        return conflictingBundleIDs.contains { declared in
            guard declared.hasSuffix("*") else { return runningBundleIDs.contains(declared) }
            let prefix = declared.dropLast()
            return runningBundleIDs.contains { $0.hasPrefix(prefix) }
        }
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
