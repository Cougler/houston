import Foundation

struct ActiveSession: Identifiable, Equatable {
    let id: Int32          // pid
    let cwd: String
    let contextSize: Int
    let contextWindow: Int
    let lastActivityMs: Int64?
    /// True when this claude process is a descendant of *this* Houston process,
    /// i.e. it runs in a pane Houston hosts and can therefore be displayed.
    /// Sessions started in Ghostty, VS Code, or a script are observable (their
    /// transcripts are on disk) but not displayable — Houston doesn't hold
    /// their pty. The sidebar shows only owned sessions.
    let isHoustonOwned: Bool
    /// The session id (its transcript's basename) and transcript path,
    /// when the JSONL could be matched — the fallback a terminal thread
    /// forks from when the statusline feed isn't installed.
    var sessionId: String? = nil
    var transcriptPath: String? = nil

    var contextPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return min(1.0, Double(contextSize) / Double(contextWindow))
    }
}
