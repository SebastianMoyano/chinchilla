import Foundation
import Testing
@testable import CleanCore

/// `ScanReport` used to answer every question by walking its item list, and
/// the Deep Clean screen asked those questions from inside a view body — the
/// category list alone filtered the whole array six times, per render. The
/// answers are indexed once now, so these check the indexed answers still
/// match the naive ones.

private func item(_ path: String, _ category: CleanCategory, _ size: Int64) -> CleanItem {
    CleanItem(
        ruleID: "test", category: category, path: path, size: size,
        modified: .distantPast, safety: .safe, deleteMode: .trash, contentsOnly: false
    )
}

private let sample = ScanReport(items: [
    item("/a", .userCaches, 100),
    item("/b", .userCaches, 250),
    item("/c", .logs, 30),
    item("/d", .developer, 7),
])

@Test func totalsAndGroupingMatchTheItemList() {
    #expect(sample.totalBytes == 387)
    #expect(sample.items(in: .userCaches).map(\.path) == ["/a", "/b"])
    #expect(sample.items(in: .logs).map(\.path) == ["/c"])
    #expect(sample.items(in: .trash).isEmpty)
}

@Test func populatedCategoriesSkipsEmptyOnesAndKeepsCatalogOrder() {
    let populated = sample.populatedCategories
    #expect(Set(populated) == [.userCaches, .logs, .developer])
    // Same relative order as the catalog, so section headers don't jump around.
    let catalogOrder = CleanCategory.allCases.filter { populated.contains($0) }
    #expect(populated == catalogOrder)
}

@Test func bytesOfASelectionAddsUpOnlyWhatIsSelected() {
    #expect(sample.bytes(of: ["/a", "/c"]) == 130)
    #expect(sample.bytes(of: []) == 0)
    // Ids from an older report must not contribute phantom bytes.
    #expect(sample.bytes(of: ["/gone"]) == 0)
}

@Test func itemsForASelectionComeBackInReportOrder() {
    #expect(sample.items(ids: ["/c", "/a"]).map(\.path) == ["/a", "/c"])
    #expect(sample.items(ids: ["/nope"]).isEmpty)
}

@Test func lookupByIDFindsTheItemThatCarriesThatPath() {
    #expect(sample.item(id: "/b")?.size == 250)
    #expect(sample.item(id: "/missing") == nil)
}

@Test func duplicatePathsDoNotTrapTheIndex() {
    // The scanner dedupes by path and id *is* the path — but building the
    // index must not be the thing that discovers it ever stopped being true.
    let report = ScanReport(items: [
        item("/same", .userCaches, 10),
        item("/same", .logs, 20),
    ])
    #expect(report.item(id: "/same")?.size == 10)
    #expect(report.totalBytes == 30)
}

@Test func anEmptyReportAnswersEverythingWithNothing() {
    let empty = ScanReport()
    #expect(empty.totalBytes == 0)
    #expect(empty.populatedCategories.isEmpty)
    #expect(empty.items(in: .userCaches).isEmpty)
    #expect(empty.bytes(of: ["/a"]) == 0)
}
