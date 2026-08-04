import Foundation

/// One row per television, not one per protocol.
///
/// A set that speaks both AirPlay and DLNA was listed twice, which reads as
/// two televisions. And the choice between them isn't cosmetic: this app can
/// send that set files over DLNA, but mirroring to it is only possible through
/// macOS's own AirPlay. So the row that survives is the protocol *this app*
/// can do most with, and the AirPlay alternative is carried on it rather than
/// competing with it for space.
public enum DeviceMerge {
    /// `rank` is lowest-is-best: what the app can do most with.
    public static func merge<T>(
        _ items: [T],
        name: (T) -> String,
        rank: (T) -> Int,
        isAirPlay: (T) -> Bool
    ) -> [(item: T, alsoAirPlay: Bool)] {
        var kept: [String: (item: T, alsoAirPlay: Bool)] = [:]
        var order: [String] = []
        for item in items.sorted(by: { rank($0) < rank($1) }) {
            let key = name(item).lowercased()
            if kept[key] != nil {
                // A second sighting only adds information when it's the
                // AirPlay one; anything else is the same device again.
                if isAirPlay(item) { kept[key]?.alsoAirPlay = true }
            } else {
                kept[key] = (item, isAirPlay(item))
                order.append(key)
            }
        }
        return order.compactMap { kept[$0] }
    }
}
