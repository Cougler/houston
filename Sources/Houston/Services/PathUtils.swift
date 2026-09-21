import Foundation

extension String {
    /// `~` -> `$HOME`, leaving other path components untouched.
    var expandingTildePath: String {
        (self as NSString).expandingTildeInPath
    }

    /// Safe to interpolate into a shell command line: single-quoted, with
    /// embedded quotes escaped. Double quotes are NOT safe for this —
    /// they leave `$(…)`, backticks and `\` live, so a hostile branch
    /// name or pasted URL executes when the line hits the pty. Pair with
    /// `strippingTerminalControls` for anything not typed by the user.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Drops control characters (keeping \t and \n) from text bound for a
    /// terminal. A raw ESC can terminate the bracketed paste guard
    /// (`ESC [ 2 0 1 ~`) and a raw CR then submits whatever follows to
    /// the shell — so page-derived or repo-derived strings must pass
    /// through here before they reach a pane.
    var strippingTerminalControls: String {
        String(String.UnicodeScalarView(unicodeScalars.filter {
            $0 == "\t" || $0 == "\n"
                || $0.properties.generalCategory != .control
        }))
    }
}
