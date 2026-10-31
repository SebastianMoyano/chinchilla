import Foundation
import DiskScanKit
import SystemKit

public struct CleanFailure: Error, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

public struct CleanOutcome: Sendable {
    public var freedBytes: Int64 = 0
    public var deletedPaths: [String] = []
    public var failures: [CleanFailure] = []
    public var dryRun = false
}

/// Executes deletions. Every single path — including children of
/// contents-only items — re-validates against SafetyPolicy first.
public enum Cleaner {
    public static func clean(
        items: [CleanItem],
        dryRun: Bool,
        rules ruleList: [CleanRule] = RuleCatalog.rules
    ) async -> CleanOutcome {
        // The whole delete run — every fileExists, every trashItem, and the
        // audit-log write — is synchronous work with no awaits in it. Left in
        // an async body it squatted a cooperative lane for the duration of a
        // clean; this is the largest single unwrapped block in the codebase.
        await Blocking.run { performClean(items: items, dryRun: dryRun, rules: ruleList) }
    }

    private static func performClean(
        items: [CleanItem],
        dryRun: Bool,
        rules ruleList: [CleanRule]
    ) -> CleanOutcome {
        let rules = Dictionary(uniqueKeysWithValues: ruleList.map { ($0.id, $0) })
        var outcome = CleanOutcome(dryRun: dryRun)

        for item in items {
            guard let rule = rules[item.ruleID] else {
                outcome.failures.append(CleanFailure(path: item.path, reason: "unknown rule \(item.ruleID)"))
                continue
            }
            let roots = rule.declaredRoots
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            // contentsOnly only makes sense for directories; loose files
            // matched by the same glob (e.g. ~/Library/Caches/foo.cache)
            // are deleted directly.
            if item.contentsOnly && isDir.boolValue {
                // An unreadable directory is a failure, not a silent success —
                // otherwise we'd credit bytes we never deleted.
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: item.path) else {
                    outcome.failures.append(CleanFailure(path: item.path, reason: "directory not readable"))
                    continue
                }
                var failedHere = false
                var deletedAny = false
                for child in children {
                    let childPath = (item.path as NSString).appendingPathComponent(child)
                    switch delete(path: childPath, roots: roots, mode: item.deleteMode,
                                  unlock: rule.unlockReadOnlyTree, dryRun: dryRun) {
                    case .success:
                        deletedAny = true
                    case .failure(let failure):
                        // EBUSY/EPERM on individual cache files: attempt-and-skip.
                        outcome.failures.append(failure)
                        failedHere = true
                    }
                }
                // Item-level size is the best estimate we have; only count it
                // when something was actually removed and nothing failed.
                if !failedHere, deletedAny {
                    outcome.freedBytes += item.size
                    outcome.deletedPaths.append(item.path + "/*")
                }
            } else {
                switch delete(path: item.path, roots: roots, mode: item.deleteMode,
                              unlock: rule.unlockReadOnlyTree, dryRun: dryRun) {
                case .success:
                    outcome.freedBytes += item.size
                    outcome.deletedPaths.append(item.path)
                case .failure(let failure):
                    outcome.failures.append(failure)
                }
            }
        }

        if !dryRun {
            appendAuditLog(outcome)
        }
        return outcome
    }

    private static func delete(
        path: String, roots: [String], mode: DeleteMode, unlock: Bool = false, dryRun: Bool
    ) -> Result<Void, CleanFailure> {
        let target: String
        do {
            // Delete exactly what was checked, not the path we were handed.
            target = try SafetyPolicy.validate(path: path, declaredRoots: roots)
        } catch let violation as PolicyViolation {
            return .failure(CleanFailure(path: path, reason: violation.description))
        } catch {
            return .failure(CleanFailure(path: path, reason: error.localizedDescription))
        }
        if dryRun { return .success(()) }
        do {
            let url = URL(fileURLWithPath: target)
            if unlock { grantOwnerWrite(under: target) }
            switch mode {
            case .trash:
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            case .unlink:
                try FileManager.default.removeItem(at: url)
            }
            return .success(())
        } catch {
            return .failure(CleanFailure(path: path, reason: error.localizedDescription))
        }
    }

    /// Adds owner-write to every folder in `root` (already validated) so its
    /// entries can be unlinked — what `go clean -modcache` does before it
    /// removes the cache. Never follows symlinks or crosses volumes.
    static func grantOwnerWrite(under root: String) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        guard let ftsp = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(ftsp) }
        while let ent = fts_read(ftsp) {
            // Pre-order: unlock a folder before fts reads into it.
            guard Int32(ent.pointee.fts_info) == FTS_D,
                  let st = ent.pointee.fts_statp?.pointee,
                  st.st_mode & S_IWUSR == 0 else { continue }
            chmod(ent.pointee.fts_path, (st.st_mode & 0o7777) | S_IWUSR)
        }
    }

    // MARK: - Audit log

    public struct LastClean: Sendable {
        public let date: Date
        public let freedBytes: Int64
    }

    /// Most recent real clean, for the dashboard.
    public static func lastClean() -> LastClean? {
        // The dashboard asks on every refresh, and it only ever wants the last
        // line — no reason for that to cost more each month.
        guard let lastLine = RollingLog.tail(auditLogURL, lines: 1).first else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(AuditEntry.self, from: Data(lastLine.utf8)) else { return nil }
        return LastClean(date: entry.date, freedBytes: entry.freedBytes)
    }

    static var auditLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Chinchilla/clean-history.jsonl")
    }

    private struct AuditEntry: Codable {
        let date: Date
        let freedBytes: Int64
        let deleted: [String]
        let failures: [String]
    }

    private static func appendAuditLog(_ outcome: CleanOutcome) {
        let entry = AuditEntry(
            date: Date(),
            freedBytes: outcome.freedBytes,
            deleted: outcome.deletedPaths,
            failures: outcome.failures.map { "\($0.path): \($0.reason)" }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        RollingLog.append(data, to: auditLogURL, limit: .cleanHistory)
        // The log rotates; the lifetime counter doesn't. Same call site so
        // they can never disagree about what counted as a clean.
        CleanTotalsStore.record(freedBytes: outcome.freedBytes, at: entry.date)
    }
}
