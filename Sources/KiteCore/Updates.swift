import Foundation

/// Kite › Check for Updates…, against GitHub releases of gabekus/kite.
///
/// Arc uses Sparkle with a signed appcast. Kite has no release pipeline, notarisation or appcast yet, so it asks
/// GitHub's releases API for the latest release, compares its tag with the running version, and offers the
/// release page. Nothing is downloaded or replaced.
public enum Updates {
    public static let repository = "gabekus/kite"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases")!

    public enum Outcome: Equatable, Sendable {
        /// The latest release is not newer than the running app.
        case upToDate(current: AppVersion)
        case available(Release)
        /// The repository has no published release yet (GitHub answers 404).
        case noReleases
        case failed(String)
    }

    public struct Release: Equatable, Sendable {
        public var version: AppVersion
        public var tag: String
        public var title: String
        public var notes: String
        public var pageURL: URL
        /// A .dmg or .zip attached to the release, when there is one.
        public var download: URL?
    }

    /// Reads GitHub's answer to `latestReleaseURL`.
    public static func outcome(currentVersion: String, statusCode: Int, body: Data) -> Outcome {
        guard let current = AppVersion(currentVersion) else {
            return .failed("Kite's version (\(currentVersion)) isn't a version number.")
        }
        switch statusCode {
        case 200: break
        case 404: return .noReleases
        case 403, 429: return .failed("GitHub is limiting requests. Try again in a few minutes.")
        default: return .failed("GitHub answered with status \(statusCode).")
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: body) else {
            return .failed("GitHub's answer couldn't be read.")
        }
        // /releases/latest never returns drafts or prereleases, but don't trust it blindly.
        if release.draft == true || release.prerelease == true { return .upToDate(current: current) }
        guard let version = AppVersion(release.tag_name) else {
            return .failed("The latest release's tag (\(release.tag_name)) isn't a version number.")
        }
        guard version > current else { return .upToDate(current: current) }
        let pageURL = URL(string: release.html_url) ?? releasesPageURL
        return .available(Release(
            version: version,
            tag: release.tag_name,
            title: release.name?.isEmpty == false ? release.name! : "Kite \(version)",
            notes: release.body ?? "",
            pageURL: pageURL,
            download: preferredDownload(release.assets ?? [])
        ))
    }

    static func preferredDownload(_ assets: [GitHubRelease.Asset]) -> URL? {
        for suffix in [".dmg", ".zip"] {
            if let asset = assets.first(where: { $0.name.lowercased().hasSuffix(suffix) }) {
                return URL(string: asset.browser_download_url)
            }
        }
        return nil
    }

    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?
    }
}

/// A dotted version like "0.1.0", read from CFBundleShortVersionString or a release tag ("v0.2", "kite-1.4.2").
/// A prerelease suffix ("1.0.0-beta.2") sorts before the release itself, as in semantic versioning.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var numbers: [Int]
    public var prerelease: [String]

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Skip a prefix such as "v" or "kite-" up to the first digit.
        guard let first = rest.firstIndex(where: \.isNumber) else { return nil }
        rest = rest[first...]
        // Build metadata ("+abc") never affects ordering.
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var pre: Substring = ""
        if let dash = rest.firstIndex(of: "-") {
            pre = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
        self.prerelease = pre.isEmpty ? [] : pre.split(separator: ".").map(String.init)
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// Missing trailing numbers count as zero, so 1.2 == 1.2.0.
    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        compareNumbers(a.numbers, b.numbers) == 0 && a.prerelease == b.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let byNumber = compareNumbers(a.numbers, b.numbers)
        if byNumber != 0 { return byNumber < 0 }
        // Same numbers: a prerelease comes before the release.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true    // numeric identifiers sort before words
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func compareNumbers(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
