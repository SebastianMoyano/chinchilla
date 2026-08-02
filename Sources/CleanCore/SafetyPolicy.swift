import Foundation
import Darwin

public struct PolicyViolation: Error, Sendable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "\(reason): \(path)" }
}

/// Last line of defense. Every deletion goes through `validate` regardless of
/// what the scanner produced. Deny rules run against the symlink-resolved path.
public enum SafetyPolicy {
    /// Absolute prefixes that must never be deleted (or contain deletions),
    /// except allowlisted subtrees below.
    static let denyPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/private/var/db",
        "/private/var/vm",
        "/private/var/folders",
        "/Library/Updates",
        "/Library/Keychains",
        "/Library/Application Support/com.apple.TCC",
        NSHomeDirectory() + "/Library/Keychains",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC",
        NSHomeDirectory() + "/Library/Mobile Documents",   // iCloud Drive!
        NSHomeDirectory() + "/Library/CloudStorage",
        NSHomeDirectory() + "/Library/Messages",
        NSHomeDirectory() + "/Library/Mail",
        NSHomeDirectory() + "/Library/Photos",
        NSHomeDirectory() + "/Library/Safari",
        NSHomeDirectory() + "/Library/Application Support/CloudDocs",
        NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Desktop",
        NSHomeDirectory() + "/Pictures",
    ]

    /// Deny-prefix exceptions: subtrees inside denied prefixes that rules may
    /// legitimately target.
    static let allowPrefixes: [String] = [
        "/usr/local",
    ]

    /// Caches that hold sync/auth state — never cleanable even though they
    /// live inside cache directories.
    static let denyNameSubstrings: [String] = [
        "CloudKit", "com.apple.bird", "FamilyCircle", "com.apple.ak",
        "HomeKit", "com.apple.homed", "com.apple.passd", "com.apple.Wallet",
        "com.apple.containermanagerd", "com.apple.TCC", "MobileAsset",
    ]

    static let resolvedDenyPrefixes: [String] = denyPrefixes.map(resolve)
    static let resolvedAllowPrefixes: [String] = allowPrefixes.map(resolve)

    private static let sfRestricted: UInt32 = 0x0008_0000  // SF_RESTRICTED
    private static let ufImmutable: UInt32 = 0x0000_0002   // UF_IMMUTABLE
    private static let sfImmutable: UInt32 = 0x0002_0000   // SF_IMMUTABLE

    /// Validates that `path` is safe to delete and lies under one of the
    /// roots the triggering rule declared.
    public static func validate(path: String, declaredRoots: [String]) throws {
        let resolved = resolve(path)

        guard resolved != "/", resolved.hasPrefix("/") else {
            throw PolicyViolation(path: path, reason: "not an absolute path")
        }
        // Refuse anything shallow (e.g. "/Users" or "/Users/x").
        if resolved.split(separator: "/").count < 3 {
            throw PolicyViolation(path: resolved, reason: "path too shallow")
        }
        // Normalize both sides identically: resolvingSymlinksInPath strips
        // "/private" (so "/private/var/db" and "/var/db" compare equal).
        if !resolvedAllowPrefixes.contains(where: { resolved.isUnder($0) }) {
            if let hit = resolvedDenyPrefixes.first(where: { resolved.isUnder($0) }) {
                throw PolicyViolation(path: resolved, reason: "protected location (\(hit))")
            }
        }
        if let hit = denyNameSubstrings.first(where: { resolved.contains($0) }) {
            throw PolicyViolation(path: resolved, reason: "protected system state (\(hit))")
        }
        let roots = declaredRoots.map(resolve)
        guard roots.contains(where: { resolved.isUnder($0) }) else {
            throw PolicyViolation(path: resolved, reason: "outside declared rule roots")
        }

        var st = stat()
        if lstat(resolved, &st) == 0 {
            if st.st_flags & (sfRestricted | ufImmutable | sfImmutable) != 0 {
                throw PolicyViolation(path: resolved, reason: "SIP-restricted or immutable")
            }
        }
    }

    /// Resolves symlinks in every component except the last; the leaf itself
    /// may be a symlink (deleting a symlink is fine — following it is not).
    static func resolve(_ path: String) -> String {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        return (resolvedParent as NSString).appendingPathComponent(ns.lastPathComponent)
    }
}

extension String {
    /// True if self == prefix or self is inside the directory `prefix`.
    func isUnder(_ prefix: String) -> Bool {
        self == prefix || hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
}
