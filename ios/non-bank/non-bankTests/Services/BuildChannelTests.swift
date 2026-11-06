import XCTest
@testable import non_bank

/// Only App Store installs report analytics; test runs, debug builds,
/// TestFlight and App Review stay out of GA4.
@MainActor
final class BuildChannelTests: XCTestCase {

    func testClassify() {
        XCTAssertEqual(BuildChannel.classify(isTestRun: true, isDebugBuild: true, receiptFileName: "sandboxReceipt"), .tests)
        XCTAssertEqual(BuildChannel.classify(isTestRun: true, isDebugBuild: false, receiptFileName: "receipt"), .tests)
        XCTAssertEqual(BuildChannel.classify(isTestRun: false, isDebugBuild: true, receiptFileName: "receipt"), .debug)
        // TestFlight and App Review run on a sandbox receipt.
        XCTAssertEqual(BuildChannel.classify(isTestRun: false, isDebugBuild: false, receiptFileName: "sandboxReceipt"), .sandbox)
        XCTAssertEqual(BuildChannel.classify(isTestRun: false, isDebugBuild: false, receiptFileName: "receipt"), .appStore)
    }

    func testOnlyAppStoreInstallsCollect() {
        XCTAssertTrue(BuildChannel.appStore.collectsAnalytics)
        for channel in [BuildChannel.tests, .debug, .sandbox] {
            XCTAssertFalse(channel.collectsAnalytics, "\(channel)")
        }
    }

    /// The CI simulators that showed up in GA4 as new users: this run is
    /// recognised as a test run, and the app hosting it registered no
    /// Firebase analytics.
    func testThisTestRunSendsNothing() {
        XCTAssertEqual(BuildChannel.current, .tests)
        XCTAssertTrue(DIContainer.shared.resolve(AnalyticsServiceProtocol.self) is NoOpAnalyticsService)
    }
}
