import Foundation
import AppKit
import CleanCore
import SystemKit

/// Headless companion: `Chinchilla scan [--json]` and
/// `Chinchilla clean [--real]` (dry-run by default, safe categories only).
/// Runs before any GUI machinery — usable from scripts and cron.
enum ChinchillaCLI {
    enum Command {
        case scan(json: Bool)
        case clean(real: Bool)
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
        case "help", "--help", "-h":
            return .help
        default:
            return nil  // not a CLI invocation (e.g. --scheduled-clean, Finder args)
        }
    }

    static func run(_ command: Command) async -> Int32 {
        switch command {
        case .help:
            print(helpText)
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
      Chinchilla help             This text.

    Cleaning honors the same safety policy, running-app guard and audit log
    as the GUI (~/Library/Logs/Chinchilla/clean-history.jsonl).
    Tip: alias chinchilla="/Applications/Chinchilla.app/Contents/MacOS/Chinchilla"
    """
}
