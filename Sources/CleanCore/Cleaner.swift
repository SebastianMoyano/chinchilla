import Foundation

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
                    switch delete(path: childPath, roots: roots, mode: item.deleteMode, dryRun: dryRun) {
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
                switch delete(path: item.path, roots: roots, mode: item.deleteMode, dryRun: dryRun) {
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
        path: String, roots: [String], mode: DeleteMode, dryRun: Bool
    ) -> Result<Void, CleanFailure> {
        do {
            try SafetyPolicy.validate(path: path, declaredRoots: roots)
        } catch let violation as PolicyViolation {
            return .failure(CleanFailure(path: path, reason: violation.description))
        } catch {
            return .failure(CleanFailure(path: path, reason: error.localizedDescription))
        }
        if dryRun { return .success(()) }
        do {
            let url = URL(fileURLWithPath: path)
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

    // MARK: - Audit log

    public struct LastClean: Sendable {
        public let date: Date
        public let freedBytes: Int64
    }

    /// Most recent real clean, for the dashboard.
    public static func lastClean() -> LastClean? {
        guard let data = try? Data(contentsOf: auditLogURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lastLine = text.split(separator: "\n").last(where: { !$0.isEmpty }) else { return nil }
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
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        let url = auditLogURL
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
