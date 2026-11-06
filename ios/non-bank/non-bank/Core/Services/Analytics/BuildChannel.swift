import Foundation

/// Where this copy of the app runs. Only App Store installs report
/// analytics: test runs (CI simulators), debug builds, TestFlight and App
/// Review each open the app once on a fresh device and showed up in GA4
/// as new users who never came back — 43 of 49 "new users" over 90 days,
/// against 6 App Store downloads.
nonisolated enum BuildChannel: Equatable, Sendable {
    /// The app as the host of a unit-test run.
    case tests
    /// Built in the Debug configuration (Xcode runs).
    case debug
    /// TestFlight or App Review: an App Store build on a sandbox receipt.
    case sandbox
    case appStore

    static let current: BuildChannel = {
        var isDebugBuild = false
        #if DEBUG
        isDebugBuild = true
        #endif
        return classify(
            isTestRun: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil,
            isDebugBuild: isDebugBuild,
            receiptFileName: Bundle.main.appStoreReceiptURL?.lastPathComponent
        )
    }()

    /// - Parameter receiptFileName: the last path component of the App
    ///   Store receipt URL — "sandboxReceipt" on TestFlight and App Review,
    ///   "receipt" for an App Store install.
    static func classify(isTestRun: Bool, isDebugBuild: Bool, receiptFileName: String?) -> BuildChannel {
        if isTestRun { return .tests }
        if isDebugBuild { return .debug }
        if receiptFileName == "sandboxReceipt" { return .sandbox }
        return .appStore
    }

    /// Whether Firebase is started and events are sent at all. The user's
    /// own switch in Settings → Privacy applies on top of this.
    var collectsAnalytics: Bool { self == .appStore }
}
