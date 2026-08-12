import Foundation

/// Claude Code's `statusLine` hook, repurposed as Houston's data feed.
///
/// Claude Code pipes a JSON payload (model, context window, cost, rate limits)
/// to the configured statusline command on every assistant message. Houston
/// installs a tiny script as that command: it prints nothing — which blanks
/// the in-terminal status row *and* suppresses the built-in hint badges — and
/// dumps the payload to a file keyed by the pane's `HOUSTON_PANE` id, where
/// `StatusLineStore` picks it up for the native status bar.
///
/// This is a strictly better source than tailing transcripts: it is pushed by
/// claude itself, carries the model's real context-window size (no
/// `contextWindow(for:)` allowlist guessing), and includes account rate-limit
/// usage that never reaches the transcript at all.
///
/// Installing rewrites the user's `~/.claude/settings.json`, so it only ever
/// happens after an explicit consent dialog, and the previous `statusLine`
/// value is backed up first so Disable can restore it exactly.
enum StatusLineFeed {

    /// Where the user's Claude settings live.
    static var claudeSettingsURL: URL {
        URL(fileURLWithPath: ("~/.claude/settings.json" as String).expandingTildePath)
    }

    private static var supportDir: String {
        ("~/Library/Application Support/Houston" as String).expandingTildePath
    }

    /// The installed feed script.
    static var scriptPath: String { supportDir + "/statusline-feed.sh" }

    /// What goes into settings.json. Claude Code hands the command to
    /// `sh -c`, and `Application Support` contains a space — unquoted, the
    /// shell executed `/Users/…/Library/Application` and the status line
    /// silently died (measured: the feed script never ran at all).
    static var statusLineCommand: String { "'" + scriptPath + "'" }

    /// Directory of per-pane payload dumps (`<pane-uuid>.json`).
    static var feedDir: String { supportDir + "/statusline" }

    /// The user's pre-Houston `statusLine` value, kept for restore.
    private static var backupURL: URL {
        URL(fileURLWithPath: supportDir + "/statusline-backup.json")
    }

    /// The script consumes stdin even when it drops the payload — exiting
    /// without reading would hand claude an EPIPE.
    private static var scriptSource: String {
        """
        #!/bin/sh
        # Houston statusline feed — installed and managed by Houston.app.
        # Prints nothing (keeps Claude's in-terminal status row blank) and
        # writes the status payload where Houston's native status bar reads it.
        DIR="$HOME/Library/Application Support/Houston/statusline"
        if [ -z "$HOUSTON_PANE" ]; then
          cat > /dev/null
          exit 0
        fi
        mkdir -p "$DIR"
        TMP="$DIR/.$HOUSTON_PANE.tmp"
        cat > "$TMP" && mv -f "$TMP" "$DIR/$HOUSTON_PANE.json"
        exit 0
        """
    }

    // MARK: - Claude settings state

    enum State {
        /// Houston's feed script is the configured statusline.
        case houston
        /// The user has their own statusline configured.
        case other
        /// No statusline configured.
        case none
    }

    static var state: State {
        guard let settings = readClaudeSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .none
        }
        // The bare path matches installs made before the command was quoted.
        return command == statusLineCommand || command == scriptPath ? .houston : .other
    }

    // MARK: - Install / restore

    /// Writes the feed script and points `statusLine` at it, backing up
    /// whatever was there. Running sessions pick the change up at their next
    /// response (Claude Code reloads settings per interaction).
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: feedDir, withIntermediateDirectories: true)
        do {
            try scriptSource.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            return false
        }

        var settings = readClaudeSettings() ?? [:]
        // Back up only a foreign value — re-installing over our own config
        // must not clobber the user's real statusline with ours.
        if state != .houston {
            let backup = ["statusLine": settings["statusLine"] ?? NSNull()]
            if let data = try? JSONSerialization.data(
                withJSONObject: backup, options: [.prettyPrinted]
            ) {
                try? data.write(to: backupURL, options: .atomic)
            }
        }
        settings["statusLine"] = [
            "type": "command",
            "command": statusLineCommand,
            "padding": 0,
        ]
        return writeClaudeSettings(settings)
    }

    /// Puts the backed-up statusline back (or removes the key if the user
    /// never had one).
    @discardableResult
    static func restore() -> Bool {
        var settings = readClaudeSettings() ?? [:]
        if let data = try? Data(contentsOf: backupURL),
           let backup = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let original = backup["statusLine"], !(original is NSNull) {
            settings["statusLine"] = original
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        guard writeClaudeSettings(settings) else { return false }
        try? FileManager.default.removeItem(at: backupURL)
        return true
    }

    private static func readClaudeSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeClaudeSettings(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        return (try? data.write(to: claudeSettingsURL, options: .atomic)) != nil
    }

    // MARK: - Snapshot files

    /// Sessions die with Houston, so at launch every dump on disk is stale.
    static func clearAllSnapshots() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: feedDir) else { return }
        for name in names {
            try? fm.removeItem(atPath: feedDir + "/" + name)
        }
    }

    static func removeSnapshot(paneID: String) {
        try? FileManager.default.removeItem(atPath: feedDir + "/" + paneID + ".json")
    }

    /// Every current dump, parsed, keyed by pane id.
    static func readSnapshots() -> [String: StatusLineSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: feedDir) else { return [:] }
        var out: [String: StatusLineSnapshot] = [:]
        for name in names where name.hasSuffix(".json") {
            let path = feedDir + "/" + name
            let paneID = String(name.dropLast(".json".count))
            guard let data = fm.contents(atPath: path),
                  let snap = StatusLineSnapshot(paneID: paneID, payload: data,
                                                updatedAt: modificationDate(of: path))
            else { continue }
            out[paneID] = snap
        }
        return out
    }

    private static func modificationDate(of path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }
}

// MARK: - Snapshot

/// The slice of the statusline payload the native bar renders.
struct StatusLineSnapshot: Equatable {

    /// One account rate-limit meter (session, all-models week, per-model
    /// week), 0–100.
    struct Meter: Equatable {
        let key: String
        let label: String
        let pct: Double
    }

    let paneID: String
    let modelName: String
    /// Context used, 0–1. Nil until the session's first API response.
    let usedFraction: Double?
    let usedTokens: Int?
    let windowSize: Int?
    let costUSD: Double?
    let linesAdded: Int
    let linesRemoved: Int
    /// Account rate-limit meters in display order. Empty for accounts whose
    /// payload carries none.
    let meters: [Meter]
    let updatedAt: Date

    init?(paneID: String, payload: Data, updatedAt: Date) {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return nil }

        self.paneID = paneID
        self.updatedAt = updatedAt

        let model = obj["model"] as? [String: Any]
        modelName = model?["display_name"] as? String ?? "Claude"

        let ctx = obj["context_window"] as? [String: Any]
        usedTokens = (ctx?["total_input_tokens"] as? NSNumber)?.intValue
        windowSize = (ctx?["context_window_size"] as? NSNumber)?.intValue
        if let pct = (ctx?["used_percentage"] as? NSNumber)?.doubleValue {
            usedFraction = pct / 100
        } else if let used = usedTokens, let window = windowSize, window > 0 {
            usedFraction = Double(used) / Double(window)
        } else {
            usedFraction = nil
        }

        let cost = obj["cost"] as? [String: Any]
        costUSD = (cost?["total_cost_usd"] as? NSNumber)?.doubleValue
        linesAdded = (cost?["total_lines_added"] as? NSNumber)?.intValue ?? 0
        linesRemoved = (cost?["total_lines_removed"] as? NSNumber)?.intValue ?? 0

        // Parse every meter the payload carries rather than an allowlist —
        // per-model meters (e.g. a Fable weekly cap) appear as extra keys.
        let limits = obj["rate_limits"] as? [String: Any] ?? [:]
        meters = limits
            .compactMap { key, value -> Meter? in
                guard let pct = ((value as? [String: Any])?["used_percentage"]
                    as? NSNumber)?.doubleValue else { return nil }
                return Meter(key: key, label: Self.meterLabel(key), pct: pct)
            }
            .sorted { Self.meterOrder($0.key) < Self.meterOrder($1.key) }
    }

    /// "five_hour" → Session, "seven_day" → All models, "seven_day_fable"
    /// (or any per-model key) → the model's name.
    private static func meterLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "Session"
        case "seven_day": return "All models"
        default:
            return key
                .replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "five_hour_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func meterOrder(_ key: String) -> (Int, String) {
        switch key {
        case "five_hour": (0, key)
        case "seven_day": (1, key)
        default: (2, key)
        }
    }
}

// MARK: - Store

/// Publishes the feed dumps to the UI. A 2s poll of a handful of ~2KB local
/// files — in line with the app's other stores, and cheap enough that the
/// off-main hop is just consistency, not necessity.
@MainActor
final class StatusLineStore: ObservableObject {

    @Published private(set) var snapshots: [String: StatusLineSnapshot] = [:]

    private var timer: Timer?
    private var readInFlight = false

    func start() {
        guard timer == nil else { return }
        StatusLineFeed.clearAllSnapshots()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func reload() {
        guard !readInFlight else { return }
        readInFlight = true
        Task.detached(priority: .utility) {
            let found = StatusLineFeed.readSnapshots()
            await MainActor.run {
                self.readInFlight = false
                if found != self.snapshots { self.snapshots = found }
            }
        }
    }
}
