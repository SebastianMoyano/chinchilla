import Foundation
import Testing
@testable import SystemKit

private func statusObject(_ snapshot: StatusSnapshot) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(snapshot.json().utf8))
    return try #require(object as? [String: Any])
}

/// The JSON is a contract: a fleet script parses these keys. Renaming one is a
/// breaking change, so the shape is pinned here.
@Test func statusJSONHasEveryKeyInCamelCase() throws {
    var snapshot = StatusSnapshot()
    snapshot.freeBytes = 123
    snapshot.totalBytes = 456
    snapshot.batteryCycles = 42
    snapshot.batteryHealthPercent = 91
    snapshot.mdmEnrolled = true
    snapshot.smartStatus = "Verified"

    let object = try statusObject(snapshot)
    let expected: Set<String> = [
        "freeBytes", "totalBytes", "memoryUsedBytes", "memoryTotalBytes",
        "memoryPressure", "uptimeDays", "bootDate", "batteryCycles",
        "batteryHealthPercent", "zombieCount", "mdmEnrolled", "smartStatus",
    ]
    #expect(Set(object.keys) == expected)
    #expect(object["freeBytes"] as? Int64 == 123)
    #expect(object["batteryCycles"] as? Int == 42)
    #expect(object["mdmEnrolled"] as? Bool == true)
    #expect(object["smartStatus"] as? String == "Verified")
}

/// A desktop has no battery and `diskutil` may not report SMART. Those must
/// read as "can't answer" (absent), never as a zero a script would trust.
@Test func unknownFactsAreOmittedNotZeroed() throws {
    let object = try statusObject(StatusSnapshot())
    #expect(object["batteryCycles"] == nil)
    #expect(object["batteryHealthPercent"] == nil)
    #expect(object["mdmEnrolled"] == nil)
    #expect(object["smartStatus"] == nil)
    #expect(object["zombieCount"] as? Int == 0)
}

@Test func bootDateEncodesAsISO8601() throws {
    var snapshot = StatusSnapshot()
    snapshot.bootDate = Date(timeIntervalSince1970: 1_767_265_200)
    let boot = try #require(try statusObject(snapshot)["bootDate"] as? String)
    #expect(boot == "2026-01-01T11:00:00Z")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(StatusSnapshot.self, from: Data(snapshot.json().utf8))
    #expect(decoded.bootDate == snapshot.bootDate)
}

/// Snapshots get diffed across runs; a boot date that drifts by a second
/// would look like a reboot.
@Test func bootDateIsIdenticalAcrossCalls() {
    #expect(StatusSnapshot.bootDate() == StatusSnapshot.bootDate())
    #expect(StatusSnapshot.bootDate() < Date())
}

@Test func memoryPressureNamesAreStableStrings() {
    #expect(StatusSnapshot.name(of: .normal) == "normal")
    #expect(StatusSnapshot.name(of: .warning) == "warning")
    #expect(StatusSnapshot.name(of: .critical) == "critical")
    #expect(StatusSnapshot.name(of: .unknown) == "unknown")
}

@Test func volumeSpaceReportsPlausibleNumbers() {
    let space = VolumeSpace.forHome()
    #expect(space.total > 0)
    #expect(space.free >= 0)
    #expect(space.free <= space.total)
}

/// The whole point of `status` is remote checks that finish. HealthCheck's
/// probes are capped at 5 s each and run concurrently.
@Test func captureFinishesWellWithinItsBudget() async throws {
    let started = Date()
    let snapshot = await StatusSnapshot.capture()
    #expect(Date().timeIntervalSince(started) < 15)
    #expect(snapshot.totalBytes > 0)
    #expect(snapshot.bootDate < Date())
}
