import XCTest
@testable import slopWidget

final class WindowCyclingTests: XCTestCase {
    private typealias Meters = UsageSnapshot.WindowMeters
    private typealias Window = UsageSnapshot.WindowMeters.Window

    private func window(_ id: String, _ percent: Double, label: String? = nil) -> Window {
        Window(id: id, label: label ?? id, percent: percent)
    }

    // MARK: WindowMeters

    func testDefaultWindowIsShownBeforeFirstTapAndFirstTapAdvances() {
        let meters = Meters(windows: [window("a", 10), window("b", 90), window("c", 50)], defaultID: "b")
        XCTAssertEqual(meters.displayed(selection: nil)?.id, "b")
        XCTAssertEqual(meters.next(after: nil), "c")
    }

    func testWithoutDefaultTheMostConstrainedWindowIsShown() {
        let meters = Meters(windows: [window("a", 10), window("b", 90), window("c", 90)])
        XCTAssertEqual(meters.displayed(selection: nil)?.id, "b")
        XCTAssertEqual(meters.mostConstrained?.id, "b")
    }

    func testCycleFollowsWindowOrderAndWraps() {
        let meters = Meters(windows: [window("a", 1), window("b", 2), window("c", 3)])
        XCTAssertEqual(meters.next(after: "a"), "b")
        XCTAssertEqual(meters.next(after: "b"), "c")
        XCTAssertEqual(meters.next(after: "c"), "a")
    }

    func testStaleSelectionFallsBackToDefault() {
        let meters = Meters(windows: [window("a", 1), window("b", 2)], defaultID: "a")
        XCTAssertEqual(meters.displayed(selection: "gone")?.id, "a")
        // A stale selection counts as "the default is showing", so a tap moves on from it.
        XCTAssertEqual(meters.next(after: "gone"), "b")
    }

    func testSingleWindowStaysPutAndEmptyHasNothing() {
        let single = Meters(windows: [window("only", 42)])
        XCTAssertEqual(single.next(after: nil), "only")
        XCTAssertEqual(single.next(after: "only"), "only")

        let empty = Meters()
        XCTAssertNil(empty.displayed(selection: nil))
        XCTAssertNil(empty.next(after: "a"))
    }

    // MARK: Snapshot helpers

    func testCycleWindowStoresSelectionPerProvider() {
        var snapshot = UsageSnapshot()
        snapshot.setWindowMeters(Meters(windows: [window("a", 1), window("b", 2)], defaultID: "a"), for: "codex")
        snapshot.setWindowMeters(Meters(windows: [window("x", 1), window("y", 2)], defaultID: "y"), for: "antigravity")

        XCTAssertEqual(snapshot.cycleWindow(for: "codex"), "b")
        XCTAssertEqual(snapshot.windowSelections, ["codex": "b"])
        XCTAssertEqual(snapshot.cycleWindow(for: "antigravity"), "x")
        XCTAssertEqual(snapshot.windowSelections, ["codex": "b", "antigravity": "x"])
        XCTAssertEqual(snapshot.cycleWindow(for: "codex"), "a")
        XCTAssertEqual(snapshot.displayedWindow(for: "codex")?.id, "a")
        XCTAssertEqual(snapshot.displayedWindow(for: "antigravity")?.id, "x")
    }

    func testStoredSelectionFromWidgetTakesPrecedenceOverSnapshot() {
        var snapshot = UsageSnapshot()
        snapshot.setWindowMeters(Meters(windows: [window("a", 1), window("b", 2), window("c", 3)]), for: "codex")
        snapshot.windowSelections = ["codex": "a"]
        XCTAssertEqual(snapshot.displayedWindow(for: "codex", stored: "c")?.id, "c")
        XCTAssertEqual(snapshot.cycleWindow(for: "codex", stored: "c"), "a")
    }

    func testCyclingWithoutWindowsLeavesSnapshotUntouched() {
        var snapshot = UsageSnapshot()
        XCTAssertNil(snapshot.cycleWindow(for: "codex"))
        XCTAssertNil(snapshot.windowSelections)
    }

    func testSettingEmptyWindowsRemovesThemButKeepsOthers() {
        var snapshot = UsageSnapshot()
        snapshot.setWindowMeters(Meters(windows: [window("a", 1)]), for: "codex")
        snapshot.setWindowMeters(Meters(windows: [window("x", 1)]), for: "antigravity")
        snapshot.setWindowMeters(Meters(), for: "codex")
        XCTAssertNil(snapshot.windowMeters?["codex"])
        XCTAssertNotNil(snapshot.windowMeters?["antigravity"])
        snapshot.setWindowMeters(nil, for: "antigravity")
        XCTAssertNil(snapshot.windowMeters)
    }

    func testOldSnapshotWithoutWindowFieldsStillDecodes() throws {
        let json = """
        {"records":{"codex":{"id":"codex","usedPercent":40,"detail":"PRO","status":"Active","updatedAt":0}},
         "updatedAt":0,
         "claudeMeters":{"fiveHour":1,"sevenDay":2},
         "claudeMeterSelection":"fiveHour",
         "providerOrder":["codex","claude"]}
        """
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.windowMeters)
        XCTAssertNil(snapshot.windowSelections)
        XCTAssertEqual(snapshot.records["codex"]?.usedPercent, 40)
        XCTAssertEqual(snapshot.claudeMeterSelection, "fiveHour")
    }

    func testSnapshotRoundTripKeepsWindowFields() throws {
        var original = UsageSnapshot()
        original.setWindowMeters(Meters(windows: [Window(id: "a", label: "5-hour", percent: 12.5, resetText: "Resets in 1h 5m")], defaultID: "a"), for: "codex")
        original.windowSelections = ["codex": "a"]
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.windowMeters, original.windowMeters)
        XCTAssertEqual(decoded.windowSelections, ["codex": "a"])
    }

    // MARK: Codex

    private func codexUsage(primary: (Int, Int)?, secondary: (Int, Int)?) throws -> ChatGPTUsage {
        func window(_ pair: (Int, Int)?) -> String {
            guard let (used, seconds) = pair else { return "null" }
            return #"{"used_percent":\#(used),"limit_window_seconds":\#(seconds),"reset_at":4102444800}"#
        }
        let json = """
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":\(window(primary)),"secondary_window":\(window(secondary))}}
        """
        return try ChatGPTUsage.decode(Data(json.utf8))
    }

    func testCodexWindowsAreShortestFirstWithWeeklyAsDefault() throws {
        let usage = try codexUsage(primary: (12, 18_000), secondary: (40, 604_800))
        let meters = try XCTUnwrap(usage.windowMeters)
        XCTAssertEqual(meters.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(meters.windows.map(\.percent), [12, 40])
        XCTAssertEqual(meters.defaultID, "secondary")
        XCTAssertEqual(meters.displayed(selection: nil)?.label, "Weekly")
        XCTAssertEqual(meters.next(after: nil), "primary")
        XCTAssertNotNil(meters.windows[0].resetText)
    }

    func testCodexWindowOrderDoesNotDependOnPrimarySecondaryNaming() throws {
        let usage = try codexUsage(primary: (40, 604_800), secondary: (12, 18_000))
        let meters = try XCTUnwrap(usage.windowMeters)
        XCTAssertEqual(meters.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(meters.windows.map(\.id), ["secondary", "primary"])
        XCTAssertEqual(meters.displayed(selection: nil)?.label, "Weekly")
    }

    func testCodexWithOneOrNoWindows() throws {
        let one = try XCTUnwrap(codexUsage(primary: (7, 604_800), secondary: nil).windowMeters)
        XCTAssertEqual(one.windows.count, 1)
        XCTAssertEqual(one.next(after: nil), "primary")
        XCTAssertNil(try codexUsage(primary: nil, secondary: nil).windowMeters)
    }

    func testCodexWindowLabels() {
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 18_000), "5-hour")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 604_800), "Weekly")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 86_400), "Daily")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 172_800), "2-day")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 7_200), "2-hour")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: 900), "15-min")
        XCTAssertEqual(ChatGPTUsage.windowLabel(seconds: nil), "Window")
    }

    func testCodexRefreshWithoutSelectionShowsWeeklyAndKeepsPlanStatus() throws {
        let usage = try codexUsage(primary: (12, 18_000), secondary: (40, 604_800))
        let snapshot = AuthManager.snapshot(merging: usage, into: UsageSnapshot())
        XCTAssertEqual(snapshot.records["codex"]?.usedPercent, 40)
        XCTAssertEqual(snapshot.records["codex"]?.detail, "Weekly")
        XCTAssertNil(snapshot.windowSelections)
        XCTAssertEqual(snapshot.windowMeters?["codex"]?.windows.count, 2)
    }

    func testCodexSelectionPersistsAcrossRefresh() throws {
        var snapshot = AuthManager.snapshot(
            merging: try codexUsage(primary: (12, 18_000), secondary: (40, 604_800)),
            into: UsageSnapshot()
        )
        XCTAssertEqual(snapshot.cycleWindow(for: "codex"), "primary")

        snapshot = AuthManager.snapshot(
            merging: try codexUsage(primary: (15, 18_000), secondary: (45, 604_800)),
            into: snapshot
        )
        XCTAssertEqual(snapshot.windowSelections?["codex"], "primary")
        XCTAssertEqual(snapshot.records["codex"]?.usedPercent, 15)
        XCTAssertEqual(snapshot.records["codex"]?.detail, "5-hour")
        // The next tap goes back to weekly.
        XCTAssertEqual(snapshot.cycleWindow(for: "codex"), "secondary")
    }

    func testCodexSelectionFallsBackWhenItsWindowDisappears() throws {
        var snapshot = UsageSnapshot()
        snapshot.windowSelections = ["codex": "primary"]
        snapshot = AuthManager.snapshot(
            merging: try codexUsage(primary: nil, secondary: (40, 604_800)),
            into: snapshot
        )
        XCTAssertEqual(snapshot.records["codex"]?.detail, "Weekly")
        XCTAssertEqual(snapshot.records["codex"]?.usedPercent, 40)
    }

    // MARK: Antigravity

    private func antigravityUsage(_ buckets: String) throws -> AntigravityUsage {
        try JSONDecoder().decode(
            AntigravityUsage.self,
            from: Data(#"{"groups":[{"buckets":[\#(buckets)]}]}"#.utf8)
        )
    }

    private func bucket(_ id: String?, name: String?, window: String? = nil, remaining: Double?, disabled: Bool? = nil) -> String {
        var fields: [String] = []
        if let id { fields.append(#""bucketId":"\#(id)""#) }
        if let name { fields.append(#""displayName":"\#(name)""#) }
        if let window { fields.append(#""window":"\#(window)""#) }
        if let remaining { fields.append(#""remainingFraction":\#(remaining)"#) }
        if let disabled { fields.append(#""disabled":\#(disabled)"#) }
        fields.append(#""resetTime":"2099-01-01T00:00:00Z""#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    func testAntigravityWindowsSkipDisabledBucketsAndDefaultToMostConstrained() throws {
        let usage = try antigravityUsage([
            bucket("gem", name: "Gemini", remaining: 0.9),
            bucket("claude", name: "Claude", remaining: 0.25),
            bucket("off", name: "Disabled", remaining: 0.0, disabled: true),
        ].joined(separator: ","))
        let meters = try XCTUnwrap(usage.windowMeters)
        XCTAssertEqual(meters.windows.map(\.label), ["Gemini", "Claude"])
        XCTAssertEqual(meters.windows.map(\.percent), [10, 75])
        XCTAssertEqual(meters.defaultID, "claude")
        XCTAssertEqual(meters.displayed(selection: nil)?.label, "Claude")
        XCTAssertEqual(meters.next(after: nil), "gem")
        XCTAssertNotNil(meters.windows[0].resetText)
    }

    func testAntigravitySameNameAcrossWindowsGetsWindowSuffix() throws {
        let usage = try antigravityUsage([
            bucket("p5", name: "Gemini Pro", window: "5h", remaining: 0.5),
            bucket("pw", name: "Gemini Pro", window: "weekly", remaining: 0.8),
            bucket("fl", name: "Flash", remaining: 0.7),
        ].joined(separator: ","))
        let meters = try XCTUnwrap(usage.windowMeters)
        XCTAssertEqual(meters.windows.map(\.label), ["Gemini Pro (5h)", "Gemini Pro (weekly)", "Flash"])
    }

    func testAntigravityWindowIDsStayUniqueAndFallBackWithoutBucketIDs() throws {
        let usage = try antigravityUsage([
            bucket("dup", name: "A", remaining: 0.5),
            bucket("dup", name: "B", remaining: 0.6),
            bucket(nil, name: nil, window: "5h", remaining: 0.7),
        ].joined(separator: ","))
        let meters = try XCTUnwrap(usage.windowMeters)
        XCTAssertEqual(meters.windows.map(\.id), ["dup", "dup#1", "bucket-2"])
        XCTAssertEqual(meters.windows.last?.label, "5h")
        XCTAssertEqual(Set(meters.windows.map(\.id)).count, 3)
    }

    func testAntigravityFallsBackToDisabledBucketsOnlyWhenNothingElse() throws {
        let usage = try antigravityUsage(bucket("off", name: "Off", remaining: 0.4, disabled: true))
        XCTAssertEqual(usage.windowMeters?.windows.map(\.label), ["Off"])
        XCTAssertNil(try antigravityUsage(bucket("none", name: "No fraction", remaining: nil)).windowMeters)
    }

    func testAntigravityRefreshKeepsSelectionAndUpdatesFigures() throws {
        var snapshot = AuthManager.snapshot(
            merging: try antigravityUsage([
                bucket("a", name: "Alpha", remaining: 0.9),
                bucket("b", name: "Beta", remaining: 0.2),
            ].joined(separator: ",")),
            into: UsageSnapshot()
        )
        XCTAssertEqual(snapshot.records["antigravity"]?.detail, "Beta")
        XCTAssertEqual(snapshot.records["antigravity"]?.usedPercent, 80)

        XCTAssertEqual(snapshot.cycleWindow(for: "antigravity"), "a")
        snapshot = AuthManager.snapshot(
            merging: try antigravityUsage([
                bucket("a", name: "Alpha", remaining: 0.8),
                bucket("b", name: "Beta", remaining: 0.1),
            ].joined(separator: ",")),
            into: snapshot
        )
        XCTAssertEqual(snapshot.windowSelections?["antigravity"], "a")
        XCTAssertEqual(snapshot.records["antigravity"]?.detail, "Alpha")
        XCTAssertEqual(snapshot.records["antigravity"]?.usedPercent, 20)
        XCTAssertEqual(snapshot.records["antigravity"]?.hasUsageData, true)
    }

    func testAntigravityWithNoDataClearsWindowsAndKeepsNoDataRecord() throws {
        var snapshot = UsageSnapshot()
        snapshot.setWindowMeters(Meters(windows: [window("a", 1)]), for: "antigravity")
        snapshot = AuthManager.snapshot(
            merging: try antigravityUsage(bucket("x", name: "X", remaining: nil)),
            into: snapshot
        )
        XCTAssertNil(snapshot.windowMeters)
        XCTAssertEqual(snapshot.records["antigravity"]?.hasUsageData, false)
    }

    // MARK: Plumbing

    func testDefaultsKeyIsPerProvider() {
        XCTAssertEqual(WindowCycling.defaultsKey(for: "codex"), "windowSelection.codex")
        XCTAssertNotEqual(WindowCycling.defaultsKey(for: "codex"), WindowCycling.defaultsKey(for: "antigravity"))
    }
}
