import AppKit
import Foundation

/// Terminal threads (2026-10-14): highlight any run of text in a terminal
/// pane → "Ask About Selection" → a thread in the right sheet, answered
/// by a FORK of the pane's Claude session. The fork is what `/btw` does
/// inside the CLI, hosted by Houston instead: `claude -p --resume <src>
/// --fork-session --session-id <ours>` boots on the terminal's full
/// context, the question lands in the fork's own transcript, and the
/// pane's session is never touched. The fork's id is chosen up front so
/// its transcript path is known before the process exists — the thread
/// panel keys its session and re-reads by that path, exactly like a chat
/// thread (verified live against claude 2.1.299: the forked transcript
/// lands at the chosen id).
///
/// This registry remembers each fork (which pane session it came from,
/// which selection) so a re-selected anchor reopens its thread instead
/// of forking again, and so the chat list can hide fork transcripts —
/// they're side questions, not conversations.
final class TerminalThreadStore: @unchecked Sendable {
    static let shared = TerminalThreadStore()

    struct Fork: Codable, Equatable {
        let project: String
        let sourceSessionID: String
        let anchor: String
        let createdAt: Date
    }

    private let lock = NSLock()
    /// Fork session id → where it came from.
    private var forks: [String: Fork]
    private static let fileURL = URL(fileURLWithPath:
        ("~/Library/Application Support/Houston/terminal-threads.json" as NSString)
            .expandingTildeInPath)

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Fork].self, from: data) {
            forks = decoded
        } else {
            forks = [:]
        }
    }

    /// The fork already holding this selection's thread, if any.
    func forkID(source: String, anchor: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return forks.first {
            $0.value.sourceSessionID == source && $0.value.anchor == anchor
        }?.key
    }

    func register(forkID: String, project: String, source: String, anchor: String) {
        lock.lock(); defer { lock.unlock() }
        forks[forkID] = Fork(
            project: project, sourceSessionID: source, anchor: anchor,
            createdAt: Date()
        )
        if let data = try? JSONEncoder().encode(forks) {
            try? FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Whether a transcript file is one of our forks (the chat list skips
    /// them). Off-main safe — the listing runs detached.
    func isFork(file: String) -> Bool {
        let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        lock.lock(); defer { lock.unlock() }
        return forks[id] != nil
    }

    /// The anchor a terminal selection becomes. Unlike chat anchors (a
    /// 90-char key for paragraph chips) a terminal quote keeps its line
    /// breaks — code, tables and log lines are meaningless flattened —
    /// and only loses double quotes (the marker's `"]` terminator) and
    /// trailing cell padding. Capped so a whole-screen selection can't
    /// bloat every thread turn.
    static func anchor(forSelection text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\"", with: "'")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = Substring(line)
                while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
                return String(s)
            }
        var joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.count > 4000 { joined = String(joined.prefix(4000)) + "…" }
        return joined
    }

    /// The Claude session a pane is running: the statusline feed's
    /// snapshot for the pane (exact — it carries `session_id` and
    /// `transcript_path`), else the hottest Houston-owned claude process
    /// whose cwd is the pane's project. nil when no claude is running
    /// there.
    struct Source: Equatable {
        let sessionID: String
        let modelID: String?
        let modelName: String?
    }

    static func source(
        paneID: String, project: String,
        statusLines: [String: StatusLineSnapshot],
        active: [ActiveSession]
    ) -> Source? {
        if let snap = statusLines[paneID], let id = snap.sessionID {
            return Source(sessionID: id, modelID: snap.modelID, modelName: snap.modelName)
        }
        let standardized = (project as NSString).standardizingPath
        let match = active
            .filter { $0.isHoustonOwned && $0.sessionId != nil
                && ($0.cwd as NSString).standardizingPath == standardized }
            .max { ($0.lastActivityMs ?? 0) < ($1.lastActivityMs ?? 0) }
        guard let match, let id = match.sessionId else { return nil }
        return Source(sessionID: id, modelID: nil, modelName: nil)
    }
}

extension Notification.Name {
    /// A terminal pane's selection wants a thread. userInfo: paneID,
    /// project, selection (raw text).
    static let houstonOpenTerminalThread = Notification.Name("houstonOpenTerminalThread")
}
