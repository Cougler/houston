import AppKit
import Foundation

/// Checks GitHub Releases for a newer Houston and surfaces it in the UI.
///
/// The repo is public, so the unauthenticated Releases API is enough:
/// `GET /repos/Cougler/houston/releases/latest`, tags `vX.Y.Z` (created with
/// `gh release create vX.Y.Z dist/Houston.dmg`). The DMG asset's download URL
/// is preferred; the release page is the fallback when a release has no DMG.
///
/// Automatic checks run at launch and every 6 hours while running, throttled
/// to one network call per 4 hours across relaunches. Debug builds carry no
/// bundle version (`swift run` has no Info.plist), so they never auto-check
/// or nag — only the packaged app does. A manual check works everywhere and
/// always reports its outcome, including "you're up to date".
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update: Equatable {
        let version: String
        /// The DMG asset when the release has one, else the release page.
        let url: URL
    }

    /// Set while a newer release exists — the footer/rail pill's source.
    @Published private(set) var available: Update?

    /// nil in debug builds.
    static let currentVersion: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private static let api =
        URL(string: "https://api.github.com/repos/Cougler/houston/releases/latest")!
    private static let lastCheckKey = "UpdateCheckerLastCheck"
    private var timer: Timer?

    func start() {
        guard Self.currentVersion != nil else { return }
        Task { await autoCheck() }
        // Long-running instances still hear about new releases.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.autoCheck() }
        }
    }

    private func autoCheck() async {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 4 * 3600 else { return }
        _ = try? await refresh()
    }

    /// Menu-driven check: always hits the network, always answers — a newer
    /// version (with a Download button), up to date, or the error.
    func checkInteractively() {
        Task {
            do {
                presentResult(try await refresh())
            } catch {
                presentError(error)
            }
        }
    }

    /// Fetches the latest release and updates `available`. Returns the
    /// update, nil when this build is current.
    private func refresh() async throws -> Update? {
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        UserDefaults.standard.set(
            Date().timeIntervalSince1970, forKey: Self.lastCheckKey
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        // No releases published yet reads as up to date, not as an error.
        if status == 404 {
            available = nil
            return nil
        }
        guard status == 200 else {
            throw NSError(
                domain: "UpdateChecker", code: status,
                userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(status)."]
            )
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latest = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        let dmg = release.assets
            .first { $0.name.hasSuffix(".dmg") }?
            .browserDownloadURL
        // A dev build compares as "0" so a manual check still demonstrates
        // the flow (auto-checks are already off without a bundle version).
        let update: Update? = Self.isNewer(latest, than: Self.currentVersion ?? "0")
            ? Update(version: latest, url: dmg ?? release.htmlURL)
            : nil
        available = update
        return update
    }

    /// "1.10.0" vs "1.9" — numeric per component, missing components read 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func presentResult(_ update: Update?) {
        let alert = NSAlert()
        if let update {
            alert.messageText = "Houston \(update.version) is available"
            alert.informativeText = "You're running "
                + (Self.currentVersion ?? "a development build")
                + ". Installing relaunches Houston, ending any terminal "
                + "sessions running in it."
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                // Falls back to opening the browser for dev builds and
                // DMG-less releases.
                UpdateInstaller.shared.install(update)
            }
        } else {
            alert.messageText = "You're up to date"
            alert.informativeText =
                "Houston \(Self.currentVersion ?? "") is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }
}
