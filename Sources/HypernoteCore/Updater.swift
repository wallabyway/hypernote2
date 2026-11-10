import AppKit
import Foundation
import Security

/// A newer release published on GitHub.
public struct ReleaseInfo: Equatable {
    public var version: String
    public var notes: String
    public var zipURL: URL
    public var pageURL: URL

    func json() -> [String: Any] {
        ["version": version, "notes": notes, "pageURL": pageURL.absoluteString]
    }
}

public enum AppVersion {
    /// Version of the running bundle ("0.0.0" for `swift run` / tests).
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Numeric dotted comparison; tolerates a leading "v" and missing components ("0.3" == "0.3.0").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// Safety: the downloaded app must satisfy the running app's designated requirement (same bundle
/// id, same signing certificate). That's also what macOS privacy permissions are tied to, so
/// Microphone / System Audio access carries over to the new version.
@MainActor
public final class Updater {
    public static let repo = "wallabyway/hypernote2"
    public let currentVersion: String
    public private(set) var available: ReleaseInfo?
    public private(set) var lastChecked: Date?
    private let session: URLSession

    public init(session: URLSession = .shared, currentVersion: String = AppVersion.current) {
        self.session = session
        self.currentVersion = currentVersion
    }

    /// Returns the latest release if it's newer than the running version, else nil.
    @discardableResult
    public func check() async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Hypernote2/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HypernoteError.message("Couldn't reach GitHub to check for updates.")
        }
        let release = try Self.parse(data)
        lastChecked = Date()
        available = AppVersion.isNewer(release.version, than: currentVersion) ? release : nil
        return available
    }

    nonisolated static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let r = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = r.assets.first(where: { $0.name.hasPrefix("Hypernote2") && $0.name.hasSuffix(".zip") }) else {
            throw HypernoteError.message("The latest release has no Hypernote2 download.")
        }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return ReleaseInfo(version: version, notes: r.body ?? "", zipURL: zip.browser_download_url, pageURL: r.html_url)
    }

    /// Downloads, verifies and swaps in `release`, then quits so the helper can relaunch the new copy.
    public func install(_ release: ReleaseInfo) async throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw HypernoteError.message("Updates only work for the installed Hypernote2.app.")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw HypernoteError.message("Can't write to \(target.deletingLastPathComponent().path).")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hypernote2-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await session.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HypernoteError.message("Downloading the update failed.")
        }
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let newApp = work.appendingPathComponent("Hypernote2.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw HypernoteError.message("The update doesn't contain Hypernote2.app.")
        }
        try Self.verifySameSigner(newApp)
        let newVersion = Bundle(url: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion.isNewer(newVersion, than: currentVersion) else {
            throw HypernoteError.message("The downloaded app (\(newVersion)) isn't newer than this one.")
        }

        // Swap after we exit: keep the old copy until the new one is in place, roll back on failure.
        let old = target.path, staged = newApp.path, backup = target.path + ".old"
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup)"
        if mv "\(old)" "\(backup)" && /usr/bin/ditto "\(staged)" "\(old)"; then
          rm -rf "\(backup)"
        else
          rm -rf "\(old)"; mv "\(backup)" "\(old)"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "\(old)" 2>/dev/null
        /usr/bin/open "\(old)"
        rm -rf "\(work.path)"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        try helper.run()
        NSApp.terminate(nil)
    }

    /// Throws unless `app` is validly signed by the same identity as the running app.
    nonisolated static func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw HypernoteError.message("This copy of Hypernote2 isn't signed, so it can't verify updates.") }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HypernoteError.message("The update isn't a valid app.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            throw HypernoteError.message("The update isn't signed by the same developer as this app (OSStatus \(status)), so it wasn't installed.")
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw HypernoteError.message("Unpacking the update failed.") }
    }
}
