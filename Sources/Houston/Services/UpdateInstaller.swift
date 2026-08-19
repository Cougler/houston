import AppKit
import Foundation

/// Installs an update in place: downloads the release DMG, verifies the app
/// inside it is genuinely Houston (Developer ID team + Gatekeeper), swaps the
/// running bundle for the new one, and relaunches.
///
/// Only a packaged app can do this — a dev build (`swift run`) has no bundle
/// to swap, and a release without a DMG asset has nothing to install — both
/// fall back to opening the URL in the browser. The old bundle is moved aside
/// before the copy and restored if anything fails, so a botched install never
/// leaves an empty Applications slot.
@MainActor
final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum Phase: Equatable {
        case idle
        case downloading
        case installing
    }

    /// The pill renders "Updating…" while this isn't idle.
    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool { phase != .idle }

    /// The only team whose signature an update is accepted from.
    private nonisolated static let teamID = "4CDVHNL984"

    /// Pill-click entry point: confirms first — installing relaunches
    /// Houston, and sessions die with Houston.
    func requestInstall(_ update: UpdateChecker.Update) {
        guard canSelfInstall(update) else {
            NSWorkspace.shared.open(update.url)
            return
        }
        guard !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Install Houston \(update.version)?"
        alert.informativeText = "Houston will relaunch to finish the update. "
            + "Any terminal sessions running in Houston will end."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            install(update)
        }
    }

    /// Straight to work, no confirmation — for callers whose UI already
    /// warned (the manual check's alert).
    func install(_ update: UpdateChecker.Update) {
        guard canSelfInstall(update) else {
            NSWorkspace.shared.open(update.url)
            return
        }
        guard !isBusy else { return }
        phase = .downloading
        let destPath = Bundle.main.bundlePath
        Task {
            do {
                let dmg = try await Self.download(update.url)
                phase = .installing
                try await Task.detached(priority: .userInitiated) {
                    try Self.swapBundle(from: dmg, into: destPath)
                }.value
                Self.relaunch(destPath)
                NSApp.terminate(nil)
            } catch {
                phase = .idle
                presentFailure(error, fallback: update.url)
            }
        }
    }

    /// Self-install needs a DMG to install and a real .app bundle to replace.
    private func canSelfInstall(_ update: UpdateChecker.Update) -> Bool {
        update.url.pathExtension == "dmg"
            && Bundle.main.bundlePath.hasSuffix(".app")
    }

    // MARK: - The work

    private nonisolated static func download(_ url: URL) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else {
            throw failure("The download failed (HTTP \(status)).")
        }
        // The session deletes its temp file when this call returns — claim
        // it first.
        let dmg = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Houston-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)
        return dmg
    }

    /// Mount → verify → move the old bundle aside → copy the new one in →
    /// unmount. Throws with the old bundle restored on any failure.
    private nonisolated static func swapBundle(
        from dmg: URL, into destPath: String
    ) throws {
        defer { try? FileManager.default.removeItem(at: dmg) }
        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("houston-update-mount-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", "attach", dmg.path,
                "-nobrowse", "-readonly", "-mountpoint", mount.path)
        defer {
            try? run("/usr/bin/hdiutil", "detach", mount.path, "-force")
        }

        let fm = FileManager.default
        guard let appName = try fm.contentsOfDirectory(atPath: mount.path)
            .first(where: { $0.hasSuffix(".app") }) else {
            throw failure("The update image contains no app.")
        }
        let newApp = mount.appendingPathComponent(appName)

        // Not an update unless it's OUR app: intact signature, our team,
        // and Gatekeeper-accepted (i.e. still notarized).
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)
        let signInfo = try run("/usr/bin/codesign", "-dv", "--verbose=2", newApp.path)
        guard signInfo.contains("TeamIdentifier=\(teamID)") else {
            throw failure("The update isn't signed by Houston's developer.")
        }
        try run("/usr/sbin/spctl", "--assess", "--type", "execute", newApp.path)

        // The running executable keeps its inode, so moving the bundle out
        // from under ourselves is safe — and gives us a rollback.
        let aside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Houston-previous-\(UUID().uuidString).app")
        try fm.moveItem(atPath: destPath, toPath: aside.path)
        do {
            // ditto preserves the signature, resource forks, and permissions
            // — a plain copy can invalidate the seal.
            try run("/usr/bin/ditto", newApp.path, destPath)
        } catch {
            try? fm.removeItem(atPath: destPath)
            try? fm.moveItem(atPath: aside.path, toPath: destPath)
            throw error
        }
        // The image download carries quarantine; the app is notarized and
        // stapled, but stripping it avoids app translocation on relaunch.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", destPath)
        try? fm.removeItem(at: aside)
    }

    /// A detached child that waits for this process to exit, then opens the
    /// new bundle — children outlive their parent, so this survives
    /// `NSApp.terminate`.
    private nonisolated static func relaunch(_ path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \"\(path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
    }

    @discardableResult
    private nonisolated static func run(
        _ tool: String, _ args: String...
    ) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let name = (tool as NSString).lastPathComponent
            throw failure("\(name) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(
            domain: "UpdateInstaller", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func presentFailure(_ error: Error, fallback: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the update"
        alert.informativeText = error.localizedDescription
            + "\n\nYou can download it manually instead."
        alert.addButton(withTitle: "Download in Browser")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fallback)
        }
    }
}
