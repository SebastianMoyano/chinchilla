import Foundation
import Testing
@testable import CastKit

private struct Fake {
    let name: String
    let rank: Int          // 0 = we can do most with it
    let airplay: Bool
}

private func merge(_ items: [Fake]) -> [(item: Fake, alsoAirPlay: Bool)] {
    DeviceMerge.merge(items, name: \.name, rank: \.rank, isAirPlay: \.airplay)
}

@Suite("One row per television")
struct DeviceMergeTests {
    /// The LG answers on AirPlay and DLNA, and was listed twice — which reads
    /// as two televisions in the room.
    @Test("A set found on two protocols becomes one row")
    func mergesDuplicates() {
        let merged = merge([
            Fake(name: "LG webOS", rank: 3, airplay: true),
            Fake(name: "LG webOS", rank: 2, airplay: false),
        ])
        #expect(merged.count == 1)
    }

    /// Keeping the AirPlay row would leave a set we *can* send files to
    /// looking like one we can't touch at all.
    @Test("The surviving row is the one the app can use")
    func keepsTheUsefulProtocol() throws {
        let merged = merge([
            Fake(name: "LG webOS", rank: 3, airplay: true),
            Fake(name: "LG webOS", rank: 0, airplay: false),
        ])
        let kept = try #require(merged.first)
        #expect(kept.item.rank == 0)
        #expect(kept.alsoAirPlay, "the alternative is carried, not discarded")
    }

    @Test("An AirPlay-only device still appears, flagged as such")
    func airplayOnlySurvives() throws {
        let merged = merge([Fake(name: "Cine en casa", rank: 3, airplay: true)])
        let kept = try #require(merged.first)
        #expect(kept.alsoAirPlay)
    }

    @Test("Different televisions stay separate")
    func distinctDevicesAreKept() {
        let merged = merge([
            Fake(name: "Cine en casa", rank: 3, airplay: true),
            Fake(name: "4K SMART TV", rank: 0, airplay: false),
        ])
        #expect(merged.count == 2)
    }

    /// Names arrive from different protocols with different casing.
    @Test("Case doesn't split one television into two")
    func caseInsensitive() {
        let merged = merge([
            Fake(name: "LG webOS TV", rank: 3, airplay: true),
            Fake(name: "lg webos tv", rank: 2, airplay: false),
        ])
        #expect(merged.count == 1)
    }
}
