import Foundation

/// Orchestrates the one-click Handoff: a full context reset that round-trips
/// through the mission log.
///
///   /log-mission  →  (wait for missionlog.md to change)  →  /clear  →  /handoff
///
/// A skill can't do this alone — the model cannot `/clear` its own context —
/// so Houston, which owns the pty, sequences it. The log write is the
/// observable signal that step one finished: `missionlog.md`'s mtime changes,
/// then a short settle period lets the turn wind down before `/clear` fires.
@MainActor
final class HandoffCoordinator: ObservableObject {

    /// Project paths with a handoff in flight — drives the menu's state.
    @Published private(set) var active: Set<String> = []

    /// Give the model this long to write the log before giving up.
    private let timeout: TimeInterval = 180
    /// After the log file changes, wait this long for the turn to finish.
    private let settle: TimeInterval = 3

    func handoff(path: String) {
        guard !active.contains(path) else { return }
        active.insert(path)

        let logPath = path + "/missionlog.md"
        let before = Self.mtime(logPath)
        TerminalSessionManager.shared.send("/log-mission\n", to: path)

        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)
            var logWritten = false
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                if Self.mtime(logPath) != before {
                    logWritten = true
                    break
                }
            }
            if logWritten {
                try? await Task.sleep(for: .seconds(settle))
                TerminalSessionManager.shared.send("/clear\n", to: path)
                try? await Task.sleep(for: .seconds(1.5))
                TerminalSessionManager.shared.send("/handoff\n", to: path)
            }
            // On timeout the sequence just stops — the worst case is a
            // written log with no reset, which /handoff can use later.
            active.remove(path)
        }
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 }
    }
}
