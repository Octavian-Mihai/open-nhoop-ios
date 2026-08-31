import XCTest
@testable import OpenWhoop

/// Unit tests for Trends card order persistence and sanitization.
final class TrendsLayoutTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "TrendsLayoutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suite = defaults.volatileDomainNames.first {
            defaults.removePersistentDomain(forName: suite)
        }
        defaults = nil
        super.tearDown()
    }

    func testDefaultOrderMatchesDefaultTrendOrder() {
        XCTAssertEqual(TrendsLayoutStorage.loadOrder(defaults: defaults), MetricKind.defaultTrendOrder)
        XCTAssertEqual(MetricKind.allTrendCases, MetricKind.defaultTrendOrder)
    }

    func testSaveLoadRoundTrip_customOrder() {
        let custom: [MetricKind] = [.rawHR, .recovery, .hrv, .rhr, .strain, .sleepDuration]
        TrendsLayoutStorage.saveOrder(custom, defaults: defaults)
        XCTAssertEqual(TrendsLayoutStorage.loadOrder(defaults: defaults), custom)
    }

    func testSanitize_dropsUnknownAndDuplicates() {
        let raw = ["rawHR", "recovery", "bogus", "recovery", "hrv", "unknown"]
        let sanitized = TrendsLayoutStorage.sanitize(raw)
        XCTAssertEqual(sanitized, [.rawHR, .recovery, .hrv])
    }

    func testMergeWithDefaults_appendsMissingKinds() {
        let partial: [MetricKind] = [.rawHR, .recovery]
        let merged = TrendsLayoutStorage.mergeWithDefaults(partial)
        XCTAssertEqual(merged.first, .rawHR)
        XCTAssertEqual(merged.last, .sleepDuration)
        XCTAssertEqual(Set(merged), Set(MetricKind.allTrendCases))
        XCTAssertEqual(merged.count, MetricKind.allTrendCases.count)
    }

    func testLoadOrder_sanitizesInvalidStoredValues() {
        let raw = ["rawHR", "nope", "recovery", "recovery", "hrv"]
        let data = try! JSONEncoder().encode(raw)
        defaults.set(data, forKey: TrendsLayoutStorage.orderKey)

        let loaded = TrendsLayoutStorage.loadOrder(defaults: defaults)
        XCTAssertEqual(loaded.prefix(3).map(\.self), [.rawHR, .recovery, .hrv])
        XCTAssertEqual(Set(loaded), Set(MetricKind.allTrendCases))
    }

    func testResetRestoresDefault() {
        TrendsLayoutStorage.saveOrder([.rawHR, .strain], defaults: defaults)
        TrendsLayoutStorage.resetToDefault(defaults: defaults)
        XCTAssertEqual(TrendsLayoutStorage.loadOrder(defaults: defaults), MetricKind.defaultTrendOrder)
    }

    func testSaveIncrementsVersionCounter() {
        let before = defaults.integer(forKey: TrendsLayoutStorage.versionKey)
        TrendsLayoutStorage.saveOrder(MetricKind.defaultTrendOrder, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: TrendsLayoutStorage.versionKey), before + 1)
    }
}
