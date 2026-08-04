import Foundation
import DiskScanKit

// MARK: - Wire framing (Chrome native messaging: 32-bit LE length + JSON)

public enum NativeMessagingCodec {
    /// 1 MB host→browser limit per Chrome's documentation.
    public static let maxMessageSize = 1 << 20

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(json)
        return framed
    }

    public static func length(from header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(UInt32(littleEndian: value))
        guard length > 0, length <= maxMessageSize else { return nil }
        return length
    }
}

// MARK: - Mailbox (GUI ↔ host live in different processes)

public struct TabGuardDesired: Codable, Sendable, Equatable {
    public var settings: [String: JSONValue]
    public var gamingActive: Bool
    public var pauseVideos: Bool
    public var seq: Int

    public init(settings: [String: JSONValue] = [:], gamingActive: Bool = false,
                pauseVideos: Bool = false, seq: Int = 0) {
        self.settings = settings
        self.gamingActive = gamingActive
        self.pauseVideos = pauseVideos
        self.seq = seq
    }
}

public struct TabGuardEvent: Codable, Sendable {
    public let seq: Int
    public let type: String
    public var urls: [String]?
    public var all: Bool?

    public init(seq: Int, type: String, urls: [String]? = nil, all: Bool? = nil) {
        self.seq = seq
        self.type = type
        self.urls = urls
        self.all = all
    }
}

public struct TabGuardStatus: Codable, Sendable {
    public var connectedAt: Date?
    public var lastMessageAt: Date?
    public var tabs: Int = 0
    public var discarded: Int = 0
    public var coldSavedCount: Int = 0
    public var estSavedBytes: Int64 = 0

    public init() {}

    /// The extension pings every 30 s; anything older than 90 s means gone.
    public var isConnected: Bool {
        guard let last = lastMessageAt else { return false }
        return Date().timeIntervalSince(last) < 90
    }
}

/// Minimal JSON-passthrough value so settings stay schemaless in Swift.
public enum JSONValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported")) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        }
    }
}

public enum TabGuardMailbox {
    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Chinchilla/TabGuard")
    }
    public static var desiredURL: URL { directory.appendingPathComponent("desired.json") }
    public static var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }

    /// One status file per host connection: Chrome spawns one host process
    /// per profile, so "status-<pid>.json" keeps multi-profile stats from
    /// clobbering each other; the GUI aggregates all fresh files.
    public static func statusURL(pid: Int32) -> URL {
        directory.appendingPathComponent("status-\(pid).json")
    }

    public static func allStatusURLs() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("status-") }
    }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func readDesired() -> TabGuardDesired? {
        guard let data = try? Data(contentsOf: desiredURL) else { return nil }
        return try? JSONDecoder().decode(TabGuardDesired.self, from: data)
    }

    public static func writeDesired(_ desired: TabGuardDesired) {
        ensureDirectory()
        if let data = try? JSONEncoder().encode(desired) {
            try? data.write(to: desiredURL, options: .atomic)
        }
    }

    public static func appendEvent(_ event: TabGuardEvent) {
        ensureDirectory()
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: eventsURL)
        }
    }

    public static func readEvents(afterSeq seq: Int) -> [TabGuardEvent] {
        guard let data = try? Data(contentsOf: eventsURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(TabGuardEvent.self, from: Data($0.utf8)) }
            .filter { $0.seq > seq }
    }

    public static func maxEventSeq() -> Int {
        readEvents(afterSeq: -1).map(\.seq).max() ?? 0
    }

    /// Aggregate view across every live connection (one per browser profile):
    /// sums the stats and reports how many profiles are connected. Stale
    /// files (dead hosts) are pruned as a side effect.
    public static func aggregateStatus() -> (combined: TabGuardStatus, connections: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var combined = TabGuardStatus()
        var connections = 0
        for url in allStatusURLs() {
            guard let data = try? Data(contentsOf: url),
                  let status = try? decoder.decode(TabGuardStatus.self, from: data) else { continue }
            if status.isConnected {
                connections += 1
                combined.tabs += status.tabs
                combined.discarded += status.discarded
                combined.coldSavedCount += status.coldSavedCount
                combined.estSavedBytes += status.estSavedBytes
                if combined.lastMessageAt.map({ status.lastMessageAt ?? .distantPast > $0 }) ?? true {
                    combined.lastMessageAt = status.lastMessageAt
                }
            } else if let last = status.lastMessageAt, Date().timeIntervalSince(last) > 3600 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return (combined, connections)
    }

    public static func writeStatus(_ status: TabGuardStatus, pid: Int32) {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) {
            try? data.write(to: statusURL(pid: pid), options: .atomic)
        }
    }
}

// MARK: - The host process (spawned by Chrome, one per browser profile)

/// Thin relay between the extension (stdio) and the GUI (mailbox files).
/// Holds no business logic. Exits when Chrome closes the port (stdin EOF).
public enum TabGuardHost {
    public static func run() async -> Int32 {
        TabGuardMailbox.ensureDirectory()
        let stdout = FileHandle.standardOutput
        let writeLock = Locked<Void>(())

        let pid = ProcessInfo.processInfo.processIdentifier
        var status = TabGuardStatus()
        status.connectedAt = Date()
        status.lastMessageAt = Date()
        TabGuardMailbox.writeStatus(status, pid: pid)
        let statusBox = Locked(status)

        func send(_ object: [String: Any]) {
            guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
            writeLock.withLock { _ in
                stdout.write(NativeMessagingCodec.frame(json))
            }
        }

        // Forward desired state / events to the extension.
        var lastDesired: TabGuardDesired?
        var lastEventSeq = TabGuardMailbox.maxEventSeq()

        let forwarder = Task {
            while !Task.isCancelled {
                if let desired = TabGuardMailbox.readDesired(), desired != lastDesired {
                    if let settingsData = try? JSONEncoder().encode(desired.settings),
                       let settingsObj = try? JSONSerialization.jsonObject(with: settingsData) {
                        send(["type": "settings", "settings": settingsObj])
                    }
                    send(["type": "gaming", "active": desired.gamingActive,
                          "pauseVideos": desired.pauseVideos])
                    lastDesired = desired
                }
                for event in TabGuardMailbox.readEvents(afterSeq: lastEventSeq) {
                    var message: [String: Any] = ["type": event.type]
                    if let urls = event.urls { message["urls"] = urls }
                    if let all = event.all { message["all"] = all }
                    send(message)
                    lastEventSeq = max(lastEventSeq, event.seq)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // Blocking stdin reader — ends at EOF (Chrome closed the port).
        let stdin = FileHandle.standardInput
        while true {
            guard let header = try? stdin.read(upToCount: 4), header.count == 4,
                  let length = NativeMessagingCodec.length(from: header),
                  let payload = try? stdin.read(upToCount: length), payload.count == length,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { break }

            statusBox.withLock { status in
                status.lastMessageAt = Date()
                if object["type"] as? String == "stats" {
                    status.tabs = object["tabs"] as? Int ?? status.tabs
                    status.discarded = object["discarded"] as? Int ?? status.discarded
                    status.coldSavedCount = object["coldSavedCount"] as? Int ?? status.coldSavedCount
                    status.estSavedBytes = (object["estSavedBytes"] as? NSNumber)?.int64Value ?? status.estSavedBytes
                }
                TabGuardMailbox.writeStatus(status, pid: pid)
            }
        }
        forwarder.cancel()
        try? FileManager.default.removeItem(at: TabGuardMailbox.statusURL(pid: pid))
        return 0
    }
}
