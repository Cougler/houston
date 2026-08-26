import Foundation

/// Environment prepared for a claude session Houston spawns itself.
///
/// Claude Code marks its own child processes with `CLAUDE_CODE_*` variables.
/// If Houston is launched from a shell that is already inside a claude session
/// (which happens whenever Houston is started from a terminal, and always
/// during development), those markers are inherited by every pane Houston
/// opens. A pane that inherits `CLAUDE_CODE_CHILD_SESSION` is treated as a
/// nested sub-session: it **disables transcript saving**, never writes
/// `~/.claude/sessions/<pid>.json`, and produces no JSONL — which is exactly
/// the data `ProcessDetect` needs to compute context %. The session looks
/// fine on screen; Houston just goes blind to it.
///
/// So panes get an explicitly scrubbed environment rather than the inherited
/// one. Verified against a spike: with the markers present the spawned session
/// prints "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION
/// marker" and writes no session file.
enum TerminalEnvironment {

    /// Variables that must never leak into a spawned session.
    private static let blockedPrefixes = ["CLAUDE_CODE_"]

    /// Extra vars Houston stamps on each pane so `ProcessDetect` can tie an
    /// observed pid back to the pane that owns it.
    static let paneIDKey = "HOUSTON_PANE"

    /// The env overrides handed to a surface, given a pane id.
    ///
    /// `ghostty_surface_config_s.env_vars` only *adds* variables — it can't
    /// unset an inherited one. Blocked keys are therefore explicitly set to an
    /// empty string. Verified empirically: with the markers inherited, a
    /// spawned session writes no `~/.claude/sessions/<pid>.json`; with them
    /// overridden to empty, the session file appears as normal.
    static func surfaceEnv(paneID: String) -> [String: String] {
        var env: [String: String] = [paneIDKey: paneID]
        // Vite (≥6.1 / backports) blocks non-localhost Host headers by
        // default, which breaks the share proxy's `<project>.local` tier
        // with "Blocked request. This host is not allowed." This is Vite's
        // official escape hatch for tunnels/proxies: any Vite dev server
        // started from a Houston pane accepts `.local` names with no config
        // edit. `.local` resolves only via mDNS on the LAN, so this doesn't
        // reopen the DNS-rebinding hole the allowlist exists to close.
        env["__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS"] = ".local"
        for (key, _) in ProcessInfo.processInfo.environment
        where blockedPrefixes.contains(where: { key.hasPrefix($0) }) {
            env[key] = ""
        }
        return env
    }
}
