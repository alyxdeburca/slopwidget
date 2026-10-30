import XCTest
import SwiftUI
@testable import slopWidget

final class ProviderUsageTests: XCTestCase {
    func testPercentageCalculation() {
        let item = ProviderUsageItem(
            id: "test",
            name: "Test Provider",
            shortName: "TP",
            icon: "sparkles",
            color: Color.purple,
            requestsUsed: 42,
            requestLimit: 100,
            tokensUsed: "740k",
            status: "Active"
        )
        XCTAssertEqual(item.percentage, 0.42, accuracy: 0.001)
        XCTAssertEqual(item.percentageInt, 42)
    }

    func testPercentageZeroLimit() {
        let item = ProviderUsageItem(
            id: "zero",
            name: "Zero Limit",
            shortName: "ZL",
            icon: "sparkles",
            color: Color.blue,
            requestsUsed: 10,
            requestLimit: 0,
            tokensUsed: "0k",
            status: "Disabled"
        )
        XCTAssertEqual(item.percentage, 0.0)
        XCTAssertEqual(item.percentageInt, 0)
    }

    func testPercentageOverflowClamping() {
        let item = ProviderUsageItem(
            id: "overflow",
            name: "Overflow",
            shortName: "OF",
            icon: "sparkles",
            color: Color.red,
            requestsUsed: 150,
            requestLimit: 100,
            tokensUsed: "2M",
            status: "Over Limit"
        )
        XCTAssertEqual(item.percentage, 1.0)
        XCTAssertEqual(item.percentageInt, 100)
    }

    @MainActor
    func testSampleUsageAverage() {
        let providers = SampleUsageData.providers
        XCTAssertEqual(providers.count, 4)
        let avg = SampleUsageData.averagePercentage
        XCTAssertGreaterThan(avg, 0)
        XCTAssertLessThanOrEqual(avg, 100)
    }
}
