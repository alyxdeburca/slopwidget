import XCTest
@testable import slopWidget

final class ClaudeMeterCycleTests: XCTestCase {
    private typealias Meters = UsageSnapshot.ClaudeMeters

    func testFirstTapMovesFromMostConstrainedToTheOtherWindow() {
        let weeklyHigher = Meters(fiveHour: 12, sevenDay: 62)
        XCTAssertEqual(weeklyHigher.displayedWindow(selection: nil), "sevenDay")
        XCTAssertEqual(weeklyHigher.nextWindow(after: nil), "fiveHour")

        let fiveHourHigher = Meters(fiveHour: 80, sevenDay: 20)
        XCTAssertEqual(fiveHourHigher.displayedWindow(selection: nil), "fiveHour")
        XCTAssertEqual(fiveHourHigher.nextWindow(after: nil), "sevenDay")
    }

    func testCycleOrderIsFiveHourThenWeeklyThenWraps() {
        let meters = Meters(fiveHour: 10, sevenDay: 20)
        XCTAssertEqual(Meters.cycleOrder, ["fiveHour", "sevenDay"])
        XCTAssertEqual(meters.nextWindow(after: "fiveHour"), "sevenDay")
        XCTAssertEqual(meters.nextWindow(after: "sevenDay"), "fiveHour")
    }

    func testTiePrefersFiveHour() {
        XCTAssertEqual(Meters(fiveHour: 40, sevenDay: 40).displayedWindow(selection: nil), "fiveHour")
    }

    func testWindowsWithoutDataAreSkipped() {
        let onlyWeekly = Meters(fiveHour: nil, sevenDay: 30)
        XCTAssertEqual(onlyWeekly.availableWindows, ["sevenDay"])
        XCTAssertEqual(onlyWeekly.nextWindow(after: nil), "sevenDay")
        XCTAssertEqual(onlyWeekly.nextWindow(after: "sevenDay"), "sevenDay")
        // A stale selection pointing at a window with no data falls back.
        XCTAssertEqual(onlyWeekly.displayedWindow(selection: "fiveHour"), "sevenDay")

        let onlyFiveHour = Meters(fiveHour: 5, sevenDay: nil)
        XCTAssertEqual(onlyFiveHour.nextWindow(after: "fiveHour"), "fiveHour")
    }

    func testNoDataMeansNothingToDisplayOrCycle() {
        let empty = Meters()
        XCTAssertNil(empty.displayedWindow(selection: nil))
        XCTAssertNil(empty.nextWindow(after: "fiveHour"))
    }

    func testLabels() {
        XCTAssertEqual(Meters.label(for: "fiveHour"), "5-hour")
        XCTAssertEqual(Meters.label(for: "sevenDay"), "Weekly")
    }

    func testRefreshWithoutSelectionShowsMostConstrainedWindow() {
        let usage = ClaudeUsage(fiveHour: .init(utilization: 12.4), sevenDay: .init(utilization: 61.6))
        let snapshot = AuthManager.snapshot(merging: usage, into: UsageSnapshot())
        XCTAssertEqual(snapshot.claudeMeters, Meters(fiveHour: 12.4, sevenDay: 61.6))
        XCTAssertNil(snapshot.claudeMeterSelection)
        XCTAssertEqual(snapshot.records["claude"]?.usedPercent, 62)
        XCTAssertEqual(snapshot.records["claude"]?.detail, "Weekly")
    }

    func testSelectionPersistsAcrossRefresh() {
        var snapshot = AuthManager.snapshot(
            merging: ClaudeUsage(fiveHour: .init(utilization: 12), sevenDay: .init(utilization: 62)),
            into: UsageSnapshot()
        )
        // User taps once: weekly was shown, so 5-hour is selected.
        snapshot.claudeMeterSelection = snapshot.claudeMeters?.nextWindow(after: snapshot.claudeMeterSelection)
        XCTAssertEqual(snapshot.claudeMeterSelection, "fiveHour")

        // A refresh brings new figures where weekly is still the higher one.
        snapshot = AuthManager.snapshot(
            merging: ClaudeUsage(fiveHour: .init(utilization: 15), sevenDay: .init(utilization: 70)),
            into: snapshot
        )
        XCTAssertEqual(snapshot.claudeMeterSelection, "fiveHour")
        XCTAssertEqual(snapshot.claudeMeters, Meters(fiveHour: 15, sevenDay: 70))
        XCTAssertEqual(snapshot.records["claude"]?.usedPercent, 15)
        XCTAssertEqual(snapshot.records["claude"]?.detail, "5-hour")

        // The next tap goes back to weekly.
        XCTAssertEqual(snapshot.claudeMeters?.nextWindow(after: snapshot.claudeMeterSelection), "sevenDay")
    }

    func testRefreshFallsBackWhenSelectedWindowLosesData() {
        var snapshot = UsageSnapshot()
        snapshot.claudeMeterSelection = "fiveHour"
        snapshot = AuthManager.snapshot(
            merging: ClaudeUsage(fiveHour: nil, sevenDay: .init(utilization: 40)),
            into: snapshot
        )
        XCTAssertEqual(snapshot.records["claude"]?.detail, "Weekly")
        XCTAssertEqual(snapshot.records["claude"]?.usedPercent, 40)
    }

    func testOldSnapshotWithoutClaudeFieldsStillDecodes() throws {
        let json = """
        {"records":{"claude":{"id":"claude","usedPercent":62,"detail":"Weekly","status":"Active","updatedAt":0}},
         "updatedAt":0,
         "openCodeMeters":{"rolling":1,"weekly":2,"monthly":3},
         "openCodeMeterSelection":"weekly",
         "providerOrder":["claude","codex"]}
        """
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.claudeMeters)
        XCTAssertNil(snapshot.claudeMeterSelection)
        XCTAssertEqual(snapshot.records["claude"]?.usedPercent, 62)
        XCTAssertEqual(snapshot.openCodeMeterSelection, "weekly")
    }

    func testSnapshotRoundTripKeepsClaudeFields() throws {
        let original = UsageSnapshot(
            claudeMeters: Meters(fiveHour: 1, sevenDay: nil),
            claudeMeterSelection: "fiveHour"
        )
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.claudeMeters, original.claudeMeters)
        XCTAssertEqual(decoded.claudeMeterSelection, "fiveHour")
    }
}
