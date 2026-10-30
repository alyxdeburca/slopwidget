import XCTest
@testable import slopWidget

final class AccessGroupTests: XCTestCase {
    func testAppDefaultGroupIsUsedAsIs() {
        XCTAssertEqual(
            SharedUsageStore.appAccessGroup(fromDefault: "ABCDE12345.com.example.slopWidget.ABCDE12345"),
            "ABCDE12345.com.example.slopWidget.ABCDE12345"
        )
    }

    func testExtensionDefaultGroupMapsBackToTheApp() {
        XCTAssertEqual(
            SharedUsageStore.appAccessGroup(
                fromDefault: "L25T52S232.XTL-L25T52S232.com.example.slopWidget.slopWidgetExtension"
            ),
            "L25T52S232.XTL-L25T52S232.com.example.slopWidget"
        )
    }

    func testMissingDefaultGroupYieldsNil() {
        XCTAssertNil(SharedUsageStore.appAccessGroup(fromDefault: nil))
        XCTAssertNil(SharedUsageStore.appAccessGroup(fromDefault: ""))
    }

    func testFallbackMatchesTheKnownXtoolGroup() {
        XCTAssertEqual(
            SharedUsageStore.fallbackAccessGroup,
            "L25T52S232.XTL-L25T52S232.com.example.slopWidget"
        )
    }
}
