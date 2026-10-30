import XCTest
@testable import slopWidget

private struct StubClaudeFetcher: ClaudeUsageFetching {
    var usage: ClaudeUsage
    func fetchUsage(accessToken: String) async throws -> ClaudeUsage { usage }
}

final class ClaudeUsageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    func testDecodesWindowsAndIgnoresUnknownKeys() throws {
        let json = """
        {"five_hour":{"utilization":12.4,"resets_at":"2026-10-30T12:00:00Z"},
         "seven_day":{"utilization":61.6,"resets_at":null},
         "seven_day_opus":null,"extra_usage":{"is_enabled":false}}
        """
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.fiveHour?.utilization, 12.4)
        XCTAssertNil(usage.sevenDay?.resetsAt)
        // The weekly window is the most constrained one.
        XCTAssertEqual(usage.usedPercent, 62)
        XCTAssertEqual(usage.detail, "Weekly")
        XCTAssertEqual(usage.statusText, "Active")
        XCTAssertTrue(usage.hasUsageData)
    }

    func testNoUtilizationMeansNoData() throws {
        let usage = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: Data(#"{"five_hour":null,"seven_day":{"utilization":null}}"#.utf8)
        )
        XCTAssertFalse(usage.hasUsageData)
        XCTAssertEqual(usage.statusText, "No data")
        XCTAssertFalse(usage.providerUsageItem.hasUsageData)
        XCTAssertEqual(usage.providerUsageItem.percentageText, "—")
    }

    func testHighAndLimitStatus() {
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 90)).statusText, "High")
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 100)).statusText, "Limit")
        XCTAssertEqual(ClaudeUsage(fiveHour: .init(utilization: 140)).usedPercent, 100)
    }

    @MainActor
    func testClaudeStartsDisconnectedAndLoginSavesToken() {
        let auth = AuthManager()
        XCTAssertFalse(auth.credentials(for: .claude).isLoggedIn)

        XCTAssertTrue(auth.login(type: .claude, apiKey: " sk-ant-oat01-x \n", identifier: "me"))
        XCTAssertEqual(auth.credentials(for: .claude).apiKey, "sk-ant-oat01-x")

        auth.logout(type: .claude)
        XCTAssertFalse(auth.credentials(for: .claude).isLoggedIn)
    }

    @MainActor
    func testRefreshWithoutTokenReportsError() async {
        let auth = AuthManager(claudeUsageService: StubClaudeFetcher(usage: ClaudeUsage()))
        let ok = await auth.refreshClaudeUsage()
        XCTAssertFalse(ok)
        XCTAssertNotNil(auth.claudeUsageError)
    }

    @MainActor
    func testRefreshPublishesUsage() async {
        let stub = StubClaudeFetcher(usage: ClaudeUsage(fiveHour: .init(utilization: 33)))
        let auth = AuthManager(claudeUsageService: stub)
        _ = auth.login(type: .claude, apiKey: "tok", identifier: "")
        let ok = await auth.refreshClaudeUsage()
        XCTAssertTrue(ok)
        XCTAssertEqual(auth.claudeUsage?.usedPercent, 33)
    }

    // MARK: Provider order

    func testOrderedSortsAndKeepsUnlistedItemsStable() {
        let items = ["a", "b", "c", "d"]
        XCTAssertEqual(UsageSnapshot.ordered(items, by: ["c", "a"], id: { $0 }), ["c", "a", "b", "d"])
        XCTAssertEqual(UsageSnapshot.ordered(items, by: nil, id: { $0 }), items)
        XCTAssertEqual(UsageSnapshot.ordered(items, by: [], id: { $0 }), items)
    }

    @MainActor
    func testNormalizedOrderDropsUnknownAndAppendsMissing() {
        let order = AuthManager.normalizedOrder(["claude", "bogus", "codex", "claude"])
        XCTAssertEqual(order, ["claude", "codex", "antigravity", "opencode-go"])
        XCTAssertEqual(AuthManager.normalizedOrder(nil), ServiceProviderType.allCases.map(\.rawValue))
    }

    @MainActor
    func testMoveProviderPersistsAndClampsAtEdges() {
        let auth = AuthManager()
        auth.moveProvider("claude", by: -1)
        XCTAssertEqual(auth.providerOrder, ["antigravity", "codex", "claude", "opencode-go"])

        auth.moveProvider("antigravity", by: -1) // already first
        auth.moveProvider("opencode-go", by: 1) // already last
        XCTAssertEqual(auth.providerOrder, ["antigravity", "codex", "claude", "opencode-go"])

        XCTAssertEqual(AuthManager().providerOrder, auth.providerOrder)

        auth.resetProviderOrder()
        XCTAssertEqual(auth.providerOrder, AuthManager.defaultProviderOrder)
    }
}
