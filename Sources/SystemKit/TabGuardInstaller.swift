import Foundation

/// Installs the native-messaging host manifest that lets the Tab Guard
/// extension talk to Chinchilla. The manifest is per-user and serves every
/// browser profile; the extension itself must be loaded once per profile.
public enum TabGuardInstaller {
    /// Deterministic — derived from the pinned "key" in the extension
    /// manifest (verify with scripts/ext-id.sh).
    public static let extensionID = "keolpdimimgbpkilajiiiobplidcdcee"
    public static let hostName = "com.sebastian.chinchilla"

    /// NativeMessagingHosts dirs of installed Chromium browsers.
    public static func manifestDirectories() -> [String] {
        let home = NSHomeDirectory()
        let candidates = [
            ("com.google.Chrome", "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            ("com.microsoft.edgemac", "\(home)/Library/Application Support/Microsoft Edge/NativeMessagingHosts"),
            ("com.brave.Browser", "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"),
        ]
        return candidates.compactMap { bundleID, dir in
            BrowserTuner.browsers.first { $0.id == bundleID }
                .flatMap { BrowserTuner.isInstalled($0) ? dir : nil }
        }
    }

    public static var isInstalled: Bool {
        manifestDirectories().contains {
            FileManager.default.fileExists(atPath: $0 + "/\(hostName).json")
        }
    }

    public struct InstallError: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    /// The manifest bakes in an absolute executable path — only a stable
    /// install location survives rebuilds.
    public static func installManifests() throws {
        guard let executable = Bundle.main.executablePath,
              !executable.contains("/.build/") else {
            throw InstallError(description: String(
                localized: "Run the installed app (e.g. /Applications/Chinchilla.app) to connect the extension."
            ))
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Chinchilla Tab Guard connector",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        var wrote = false
        for dir in manifestDirectories() {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir + "/\(hostName).json"), options: .atomic)
            wrote = true
        }
        guard wrote else {
            throw InstallError(description: String(
                localized: "No Chromium browser (Chrome, Edge, Brave) found."
            ))
        }
    }

    public static func removeManifests() {
        for dir in manifestDirectories() {
            try? FileManager.default.removeItem(atPath: dir + "/\(hostName).json")
        }
    }

    /// The unpacked extension shipped inside the app bundle, for the user to
    /// load from chrome://extensions.
    public static var bundledExtensionPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/tabguard"
        return FileManager.default.fileExists(atPath: path + "/manifest.json") ? path : nil
    }
}
