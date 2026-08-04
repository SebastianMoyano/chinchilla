import Foundation
import AppKit
import CastKit
import CleanCore
import DiskScanKit
import SystemKit

/// Headless companion: `Chinchilla scan [--json]` and
/// `Chinchilla clean [--real]` (dry-run by default, safe categories only).
/// Runs before any GUI machinery — usable from scripts and cron.
enum ChinchillaCLI {
    enum Command {
        case scan(json: Bool)
        case clean(real: Bool)
        case history(json: Bool, limit: Int)
        case status(json: Bool)
        case orphans(json: Bool)
        case mirrorTest(host: String)
        case gameStreamTest(seconds: Int)
        case castStreamTest(host: String)
        case castStreamMirror(host: String, seconds: Int, delayMs: Int)
        case help
    }

    static func command(from arguments: [String]) -> Command? {
        guard arguments.count > 1 else { return nil }
        let args = Array(arguments.dropFirst())
        switch args[0] {
        case "scan":
            return .scan(json: args.contains("--json"))
        case "clean":
            return .clean(real: args.contains("--real"))
        case "history":
            // Clamped so "--limit 0" can't masquerade as an empty history.
            return .history(json: args.contains("--json"),
                            limit: max(1, intFlag(args, "--limit") ?? 20))
        case "status":
            return .status(json: args.contains("--json"))
        case "orphans":
            return .orphans(json: args.contains("--json"))
        case "caststream-test":
            return .castStreamTest(host: args.count > 1 ? args[1] : "")
        case "caststream-mirror":
            return .castStreamMirror(
                host: args.count > 1 ? args[1] : "",
                seconds: args.count > 2 ? (Int(args[2]) ?? 30) : 30,
                delayMs: args.count > 3 ? (Int(args[3]) ?? CastStreaming.defaultTargetDelayMs)
                                        : CastStreaming.defaultTargetDelayMs
            )
        case "gamestream-test":
            return .gameStreamTest(seconds: args.count > 1 ? (Int(args[1]) ?? 180) : 180)
        case "mirror-test":
            return .mirrorTest(host: args.count > 1 ? args[1] : "")
        case "help", "--help", "-h":
            return .help
        default:
            return nil  // not a CLI invocation (e.g. --scheduled-clean, Finder args)
        }
    }

    /// Accepts both `--limit 5` and `--limit=5`; scripts write either.
    private static func intFlag(_ args: [String], _ name: String) -> Int? {
        if let index = args.firstIndex(of: name), index + 1 < args.count {
            return Int(args[index + 1])
        }
        return args.first { $0.hasPrefix(name + "=") }
            .flatMap { Int($0.dropFirst(name.count + 1)) }
    }

    static func run(_ command: Command) async -> Int32 {
        switch command {
        case .help:
            print(helpText)
            return 0
        case .castStreamTest(let host):
            guard !host.isEmpty else {
                print("usage: Chinchilla caststream-test <tv-ip>")
                return 1
            }
            return await CastStreamDiagnostics.run(host: host)
        case .castStreamMirror(let host, let seconds, let delayMs):
            guard !host.isEmpty else {
                print("usage: Chinchilla caststream-mirror <tv-ip> [seconds] [playout-delay-ms]")
                return 1
            }
            return await CastMirrorRTDiagnostics.run(
                host: host, seconds: seconds, playoutDelayMs: delayMs
            )
        case .gameStreamTest(let seconds):
            return await GameStreamDiagnostics.run(seconds: seconds)
        case .mirrorTest(let host):
            guard !host.isEmpty else {
                print("usage: Chinchilla mirror-test <tv-ip>")
                return 1
            }
            return await MirrorDiagnostics.run(host: host)
        case .history(let json, let limit):
            // Reading the log is disk I/O; it never runs on the cooperative pool.
            let entries = await Blocking.run { CleanHistory.load(limit: limit) }
            if json {
                print(CleanHistory.json(entries))
            } else if entries.isEmpty {
                print(String(localized: "No cleans recorded yet."))
            } else {
                for entry in entries { print(CleanHistory.line(entry)) }
            }
            return 0
        case .status(let json):
            // Every probe inside already has its own timeout; this is the
            // backstop so an SSH loop over 50 Macs can never wedge on one.
            guard let snapshot = try? await withTimeout(.seconds(20), "status", operation: {
                await StatusSnapshot.capture()
            }) else {
                FileHandle.standardError.write(Data("status timed out\n".utf8))
                return 1
            }
            if json {
                print(snapshot.json())
            } else {
                printStatus(snapshot)
            }
            return 0
        case .orphans(let json):
            let found = await OrphanFinder.scan()
            if json {
                // Hand-built rather than Codable: the shape is a contract for
                // whatever script consumes it, and it shouldn't drift when the
                // internal model gains a field.
                let objects: [[String: Any]] = found.map { orphan in
                    [
                        "bundleID": orphan.bundleID,
                        "name": orphan.displayName,
                        "sizeBytes": orphan.size,
                        "lastTouched": ISO8601DateFormatter().string(from: orphan.lastTouched),
                        "paths": orphan.files.map(\.path),
                    ]
                }
                if let data = try? JSONSerialization.data(
                    withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]
                ), let text = String(data: data, encoding: .utf8) { print(text) }
            } else if found.isEmpty {
                print(String(localized: "No leftovers found."))
            } else {
                let total = found.reduce(Int64(0)) { $0 + $1.size }
                for orphan in found {
                    let size = ByteCountFormatter.string(
                        fromByteCount: orphan.size, countStyle: .file
                    )
                    print("\(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(orphan.bundleID)")
                }
                print("total: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) in \(found.count) leftovers")
            }
            return 0
        case .scan(let json):
            let report = await CleanScanner.scan(hasFullDiskAccess: Permissions.hasFullDiskAccess())
            if json {
                printJSON(report)
            } else {
                printTable(report)
            }
            return 0
        case .clean(let real):
            let report = await CleanScanner.scan(hasFullDiskAccess: Permissions.hasFullDiskAccess())
            let safeItems = await MainActor.run {
                RunningAppGuard.filterOutConflicts(report.items.filter { $0.safety == .safe })
            }
            let skipped = report.items.filter { $0.safety == .safe }.count - safeItems.count
            let outcome = await Cleaner.clean(items: safeItems, dryRun: !real)
            let freed = ByteCountFormatter.string(fromByteCount: outcome.freedBytes, countStyle: .file)
            print(real ? "freed: \(freed)" : "would free: \(freed)  (dry run — pass --real to delete)")
            if skipped > 0 { print("skipped \(skipped) items (their app is running)") }
            for failure in outcome.failures.prefix(20) {
                FileHandle.standardError.write(Data("skip: \(failure.path) — \(failure.reason)\n".utf8))
            }
            return outcome.failures.isEmpty ? 0 : 2
        }
    }

    private static func printTable(_ report: ScanReport) {
        for category in CleanCategory.allCases {
            let items = report.items(in: category)
            guard !items.isEmpty else { continue }
            let bytes = items.reduce(Int64(0)) { $0 + $1.size }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            print("\(category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))  \(String(format: "%8@", size as NSString))  (\(items.count) items)")
        }
        let total = ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)
        print("total: \(total)")
    }

    private static func printStatus(_ snapshot: StatusSnapshot) {
        func bytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
        var rows: [(String, String)] = [
            (String(localized: "Free disk"),
             "\(bytes(snapshot.freeBytes)) / \(bytes(snapshot.totalBytes))"),
            (String(localized: "Memory"),
             "\(bytes(snapshot.memoryUsedBytes)) / \(bytes(snapshot.memoryTotalBytes)) (\(snapshot.memoryPressure))"),
            (String(localized: "Uptime"),
             "\(snapshot.uptimeDays) d  (\(CleanHistory.timestamp(snapshot.bootDate)))"),
        ]
        if let cycles = snapshot.batteryCycles {
            let health = snapshot.batteryHealthPercent.map { ", \($0)%" } ?? ""
            rows.append((String(localized: "Battery"),
                         String(localized: "\(cycles) cycles") + health))
        }
        rows.append((String(localized: "Zombies"), "\(snapshot.zombieCount)"))
        rows.append((String(localized: "MDM"), yesNo(snapshot.mdmEnrolled)))
        rows.append((String(localized: "SMART"), snapshot.smartStatus ?? "—"))

        let width = rows.map(\.0.count).max() ?? 0
        for (label, value) in rows {
            print("\(label.padding(toLength: width, withPad: " ", startingAt: 0))  \(value)")
        }
    }

    private static func yesNo(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? String(localized: "yes") : String(localized: "no")
    }

    private static func printJSON(_ report: ScanReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report.items),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static let helpText = """
    Chinchilla CLI 🐭✨

    USAGE:
      Chinchilla scan [--json]    List cleanable junk (all safety levels).
      Chinchilla clean [--real]   Clean SAFE categories. Dry-run unless --real.
      Chinchilla history [--json] [--limit N]
                                  Past cleans, newest first (default 20).
      Chinchilla status [--json]  One-shot health snapshot (disk, memory,
                                  uptime, battery, SMART, MDM).
      Chinchilla orphans [--json] Leftovers from apps that are already gone.
      Chinchilla help             This text.

    Cleaning honors the same safety policy, running-app guard and audit log
    as the GUI (~/Library/Logs/Chinchilla/clean-history.jsonl).
    Tip: alias chinchilla="/Applications/Chinchilla.app/Contents/MacOS/Chinchilla"
    """
}
