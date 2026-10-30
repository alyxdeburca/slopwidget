import XCTest
@testable import slopWidget

final class RefreshIntervalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    // MARK: RefreshInterval

    func testAllowedValuesAndDefault() {
        XCTAssertEqual(RefreshInterval.allowedMinutes, [5, 15, 30, 60])
        XCTAssertEqual(RefreshInterval.defaultMinutes, 15)
        XCTAssertTrue(RefreshInterval.allowedMinutes.contains(RefreshInterval.defaultMinutes))
    }

    func testNormalizedKeepsAllowedValuesAndDefaultsNil() {
        for minutes in RefreshInterval.allowedMinutes {
            XCTAssertEqual(RefreshInterval.normalized(minutes), minutes)
        }
        XCTAssertEqual(RefreshInterval.normalized(nil), 15)
    }

    func testNormalizedSnapsToTheNearestAllowedValue() {
        XCTAssertEqual(RefreshInterval.normalized(0), 5)
        XCTAssertEqual(RefreshInterval.normalized(-10), 5)
        XCTAssertEqual(RefreshInterval.normalized(9), 5)
        XCTAssertEqual(RefreshInterval.normalized(11), 15)
        XCTAssertEqual(RefreshInterval.normalized(20), 15)
        XCTAssertEqual(RefreshInterval.normalized(100), 60)
        XCTAssertEqual(RefreshInterval.normalized(100_000), 60)
        // Equidistant between 30 and 60: the shorter interval wins.
        XCTAssertEqual(RefreshInterval.normalized(45), 30)
    }

    func testLabels() {
        XCTAssertEqual(RefreshInterval.allowedMinutes.map(RefreshInterval.label(forMinutes:)),
                       ["5 min", "15 min", "30 min", "1 hour"])
    }

    // MARK: Snapshot

    func testSnapshotIntervalUsesTheDefaultWhenUnset() {
        XCTAssertEqual(UsageSnapshot().refreshInterval, 15 * 60)
        XCTAssertEqual(UsageSnapshot(refreshMinutes: 5).refreshInterval, 5 * 60)
        XCTAssertEqual(UsageSnapshot(refreshMinutes: 60).refreshInterval, 3_600)
        // A corrupt or out-of-range stored value never reaches the widget as-is.
        XCTAssertEqual(UsageSnapshot(refreshMinutes: 7).refreshInterval, 5 * 60)
        XCTAssertEqual(UsageSnapshot(refreshMinutes: 0).refreshInterval, 5 * 60)
    }

    func testOldSnapshotWithoutRefreshMinutesDecodesToTheDefault() throws {
        let json = #"{"records":{},"updatedAt":0,"providerOrder":["codex"]}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.refreshMinutes)
        XCTAssertEqual(snapshot.refreshInterval, 15 * 60)
    }

    func testSnapshotRoundTripKeepsRefreshMinutes() throws {
        let original = UsageSnapshot(refreshMinutes: 30)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.refreshMinutes, 30)
        XCTAssertEqual(decoded.refreshInterval, 30 * 60)
    }

    // MARK: AuthManager

    @MainActor
    func testDefaultsToFifteenMinutes() {
        XCTAssertEqual(AuthManager().refreshMinutes, 15)
    }

    @MainActor
    func testChoiceIsPersistedAcrossInstances() {
        let auth = AuthManager()
        auth.setRefreshMinutes(5)
        XCTAssertEqual(auth.refreshMinutes, 5)
        XCTAssertEqual(AuthManager().refreshMinutes, 5)

        auth.setRefreshMinutes(60)
        XCTAssertEqual(AuthManager().refreshMinutes, 60)
    }

    @MainActor
    func testInvalidChoiceSnapsToAnAllowedValue() {
        let auth = AuthManager()
        auth.setRefreshMinutes(7)
        XCTAssertEqual(auth.refreshMinutes, 5)
        auth.setRefreshMinutes(1_000)
        XCTAssertEqual(auth.refreshMinutes, 60)
        XCTAssertTrue(RefreshInterval.allowedMinutes.contains(AuthManager().refreshMinutes))
    }

    @MainActor
    func testCorruptStoredValueFallsBackToAnAllowedValue() {
        UserDefaults.standard.set(17, forKey: "refresh_minutes")
        XCTAssertEqual(AuthManager().refreshMinutes, 15)
        UserDefaults.standard.set("soon", forKey: "refresh_minutes")
        XCTAssertEqual(AuthManager().refreshMinutes, 15)
    }

    @MainActor
    func testResetDefaultsClearsTheChoice() {
        AuthManager().setRefreshMinutes(30)
        AuthManager.resetDefaults()
        XCTAssertEqual(AuthManager().refreshMinutes, 15)
    }

    @MainActor
    func testRefreshAllWithNothingConnectedSucceeds() async {
        // Every provider starts disconnected or on a manual login without a
        // usage source, so there is nothing to fetch; that must not read as failure.
        let auth = AuthManager()
        for type in ServiceProviderType.allCases { auth.logout(type: type) }
        let ok = await auth.refreshAllUsage()
        XCTAssertTrue(ok)
    }
}
