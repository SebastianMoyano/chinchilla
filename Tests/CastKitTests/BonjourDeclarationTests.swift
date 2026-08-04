import Foundation
import Testing

/// macOS refuses to browse a Bonjour service an app hasn't declared in its
/// Info.plist — and refuses it *silently*: the browser reports `.browsing`,
/// returns nothing, and looks exactly like an empty network.
///
/// That's how AirPlay support shipped completely inert. The code was right,
/// the discovery was right, and `_airplay._tcp` simply wasn't on the list, so
/// an Apple TV sitting three metres away was invisible to the app while a
/// command-line build found it instantly.
@Suite("Every browsed service is declared")
struct BonjourDeclarationTests {
    /// Walks up from this file to the repo root.
    private static var infoPlistURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("packaging/Info.plist")
    }

    @Test("Info.plist declares every service type the code browses")
    func declarationsCoverTheCode() throws {
        let data = try Data(contentsOf: Self.infoPlistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let declared = Set(plist["NSBonjourServices"] as? [String] ?? [])

        // Every type any discovery class asks NWBrowser for.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let sources = url.appendingPathComponent("Sources/CastKit")
        var browsed = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: nil
        )
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /\.bonjour\(type:\s*"([^"]+)"/) {
                browsed.insert(String(match.1))
            }
        }

        #expect(!browsed.isEmpty, "found no browse calls — has the pattern changed?")
        let undeclared = browsed.subtracting(declared)
        #expect(undeclared.isEmpty, "browsed but not declared in Info.plist: \(undeclared.sorted())")
    }

    @Test("The usage string mentions why we need the network")
    func usageStringExists() throws {
        let data = try Data(contentsOf: Self.infoPlistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let usage = plist["NSLocalNetworkUsageDescription"] as? String ?? ""
        #expect(usage.count > 40, "macOS shows this to the user; it has to say something")
    }
}
