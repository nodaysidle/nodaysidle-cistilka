import Foundation

/// Local scan worker concurrency (subdir listings).
enum ScanParallelism: String, CaseIterable, Identifiable, Sendable {
    case gentle
    case `default`
    case aggressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .default: "Default"
        case .aggressive: "Aggressive"
        }
    }

    /// Concurrent subdirectory workers inside `LocalDiskSource`.
    var localWorkers: Int {
        switch self {
        case .gentle: 2
        case .default: 6
        case .aggressive: 12
        }
    }

    /// Concurrent full-location scans in `ScanCoordinator`.
    var maxConcurrentLocations: Int {
        switch self {
        case .gentle: 1
        case .default: 2
        case .aggressive: 4
        }
    }

    var detail: String {
        "\(localWorkers) local workers · up to \(maxConcurrentLocations) scans"
    }
}

/// UserDefaults-backed preferences for scan behavior.
@MainActor
@Observable
final class AppPreferences {
    private enum Keys {
        static let treatPackagesAsLeaf = "prefs.treatPackagesAsLeaf"
        static let scanParallelism = "prefs.scanParallelism"
        static let defaultRootPaths = "prefs.defaultRootPaths"
        static let includeHomeInDefaults = "prefs.includeHomeInDefaults"
    }

    private let defaults: UserDefaults

    /// When true (default), `.app` packages are sized as a single leaf node.
    var treatPackagesAsLeaf: Bool {
        didSet { defaults.set(treatPackagesAsLeaf, forKey: Keys.treatPackagesAsLeaf) }
    }

    var scanParallelism: ScanParallelism {
        didSet { defaults.set(scanParallelism.rawValue, forKey: Keys.scanParallelism) }
    }

    /// Extra default local roots (absolute paths) shown / used as quick targets.
    var defaultRootPaths: [String] {
        didSet { defaults.set(defaultRootPaths, forKey: Keys.defaultRootPaths) }
    }

    /// When true, Home is always part of the default-roots list for empty-state UX.
    var includeHomeInDefaults: Bool {
        didSet { defaults.set(includeHomeInDefaults, forKey: Keys.includeHomeInDefaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Keys.treatPackagesAsLeaf) == nil {
            treatPackagesAsLeaf = true
        } else {
            treatPackagesAsLeaf = defaults.bool(forKey: Keys.treatPackagesAsLeaf)
        }

        if let raw = defaults.string(forKey: Keys.scanParallelism),
           let parsed = ScanParallelism(rawValue: raw)
        {
            scanParallelism = parsed
        } else {
            scanParallelism = .default
        }

        defaultRootPaths = defaults.stringArray(forKey: Keys.defaultRootPaths) ?? []

        if defaults.object(forKey: Keys.includeHomeInDefaults) == nil {
            includeHomeInDefaults = true
        } else {
            includeHomeInDefaults = defaults.bool(forKey: Keys.includeHomeInDefaults)
        }
    }

    /// Resolved list of default roots for UI / quick start (Home optional + custom paths).
    var resolvedDefaultRoots: [String] {
        var paths: [String] = []
        if includeHomeInDefaults {
            paths.append(NSHomeDirectory())
        }
        for p in defaultRootPaths where !paths.contains(p) {
            paths.append(p)
        }
        return paths
    }

    /// Human-facing label for a default-root path (Home vs last path component).
    static func displayName(forDefaultRoot path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        if standardized == home {
            return "Home"
        }
        let name = (standardized as NSString).lastPathComponent
        return name.isEmpty ? standardized : name
    }

    /// SF Symbol for a default-root path.
    static func systemImage(forDefaultRoot path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        return standardized == home ? "house" : "folder"
    }

    func addDefaultRoot(_ path: String) {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty, !defaultRootPaths.contains(standardized) else { return }
        defaultRootPaths.append(standardized)
    }

    func removeDefaultRoot(_ path: String) {
        defaultRootPaths.removeAll { $0 == path }
    }

    /// Build a local source configured with current package + parallelism prefs.
    func makeLocalDiskSource() -> LocalDiskSource {
        LocalDiskSource(
            treatPackagesAsLeaf: treatPackagesAsLeaf,
            maxConcurrentListings: scanParallelism.localWorkers
        )
    }
}
