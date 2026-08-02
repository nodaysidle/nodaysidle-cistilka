import XCTest
@testable import Cistilka

final class AppPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "cistilka.prefs.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testDefaultsTreatPackagesAsLeafAndDefaultParallelism() {
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.treatPackagesAsLeaf)
        XCTAssertEqual(prefs.scanParallelism, .default)
        XCTAssertEqual(prefs.scanParallelism.localWorkers, 6)
        XCTAssertEqual(prefs.scanParallelism.maxConcurrentLocations, 2)
        XCTAssertTrue(prefs.includeHomeInDefaults)
        XCTAssertTrue(prefs.resolvedDefaultRoots.contains(NSHomeDirectory()))
    }

    @MainActor
    func testParallelismLevels() {
        XCTAssertEqual(ScanParallelism.gentle.localWorkers, 2)
        XCTAssertEqual(ScanParallelism.aggressive.localWorkers, 12)
        XCTAssertEqual(ScanParallelism.gentle.maxConcurrentLocations, 1)
        XCTAssertEqual(ScanParallelism.aggressive.maxConcurrentLocations, 4)
    }

    @MainActor
    func testPersistsPackageAndParallelism() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.treatPackagesAsLeaf = false
        prefs.scanParallelism = .aggressive

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.treatPackagesAsLeaf)
        XCTAssertEqual(reloaded.scanParallelism, .aggressive)
    }

    @MainActor
    func testDefaultRootsAddRemove() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.includeHomeInDefaults = false
        prefs.addDefaultRoot("/tmp/cistilka-root")
        XCTAssertEqual(prefs.resolvedDefaultRoots, ["/tmp/cistilka-root"])
        prefs.removeDefaultRoot("/tmp/cistilka-root")
        XCTAssertTrue(prefs.resolvedDefaultRoots.isEmpty)
    }

    @MainActor
    func testDisplayNameForDefaultRoots() {
        XCTAssertEqual(AppPreferences.displayName(forDefaultRoot: NSHomeDirectory()), "Home")
        XCTAssertEqual(AppPreferences.systemImage(forDefaultRoot: NSHomeDirectory()), "house")
        XCTAssertEqual(AppPreferences.displayName(forDefaultRoot: "/tmp/cistilka-root"), "cistilka-root")
        XCTAssertEqual(AppPreferences.systemImage(forDefaultRoot: "/tmp/cistilka-root"), "folder")
    }

    @MainActor
    func testResolvedDefaultRootsDriveQuickStartList() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.includeHomeInDefaults = true
        prefs.addDefaultRoot("/Users/Shared")
        let roots = prefs.resolvedDefaultRoots
        XCTAssertEqual(roots.first, NSHomeDirectory())
        XCTAssertTrue(roots.contains("/Users/Shared"))
        // Empty-state / sidebar labels come from the same list.
        let labels = roots.map { AppPreferences.displayName(forDefaultRoot: $0) }
        XCTAssertEqual(labels.first, "Home")
        XCTAssertTrue(labels.contains("Shared"))

        prefs.includeHomeInDefaults = false
        XCTAssertEqual(prefs.resolvedDefaultRoots, ["/Users/Shared"])
        XCTAssertFalse(prefs.resolvedDefaultRoots.contains(NSHomeDirectory()))
    }

    @MainActor
    func testMakeLocalDiskSourceUsesPrefs() {
        let prefs = AppPreferences(defaults: defaults)
        prefs.treatPackagesAsLeaf = false
        prefs.scanParallelism = .gentle
        let source = prefs.makeLocalDiskSource()
        XCTAssertFalse(source.treatPackagesAsLeaf)
    }
}
