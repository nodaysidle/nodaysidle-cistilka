import Foundation

/// Public OAuth client IDs and redirect URIs (no client secrets).
struct OAuthConfig: Sendable, Equatable {
    var googleClientID: String?
    var googleRedirectURI: String?
    var microsoftClientID: String?
    var microsoftRedirectURI: String?

    /// Load from `Config/OAuth.plist` next to the package / executable, or from a
    /// bundled resource named `OAuth.plist` if present. Missing file → empty config.
    static func load() -> OAuthConfig {
        if let url = Self.resolvePlistURL(),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        {
            return OAuthConfig(
                googleClientID: Self.nonEmptyString(plist["GoogleClientID"]),
                googleRedirectURI: Self.nonEmptyString(plist["GoogleRedirectURI"]),
                microsoftClientID: Self.nonEmptyString(plist["MicrosoftClientID"]),
                microsoftRedirectURI: Self.nonEmptyString(plist["MicrosoftRedirectURI"])
            )
        }
        return OAuthConfig()
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvePlistURL() -> URL? {
        // 1) Bundle resource (if packaged later)
        if let bundled = Bundle.module.url(forResource: "OAuth", withExtension: "plist") {
            return bundled
        }
        if let main = Bundle.main.url(forResource: "OAuth", withExtension: "plist") {
            return main
        }

        // 2) Config/OAuth.plist relative to CWD / package root candidates
        let fm = FileManager.default
        var candidates: [URL] = []
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Config/OAuth.plist"))

        // Walk up from CWD looking for Package.swift + Config/OAuth.plist
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let packageMarker = dir.appendingPathComponent("Package.swift")
            let plist = dir.appendingPathComponent("Config/OAuth.plist")
            if fm.fileExists(atPath: packageMarker.path), fm.fileExists(atPath: plist.path) {
                return plist
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        for url in candidates where fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
}
