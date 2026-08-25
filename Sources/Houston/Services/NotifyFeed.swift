import AppKit
import Foundation
import UserNotifications

/// "Needs you" notifications, fed by Claude Code's hooks.
///
/// Claude Code fires a `Notification` hook when it needs the user — a
/// permission request, or sitting idle waiting for input — and a `Stop` hook
/// when a response turn finishes. Houston installs one tiny script as both:
/// it dumps the hook's JSON payload (which carries `hook_event_name`) to a
/// per-event file keyed by the pane's `HOUSTON_PANE` id, and `NotifyStore`
/// turns those into native banners, a menubar badge, and sidebar row badges.
///
/// Unlike the statusline takeover, installing is a non-destructive *merge*:
/// Houston appends its own entry to the `hooks` arrays in
/// `~/.claude/settings.json` and removal deletes exactly that entry, so the
/// user's own hooks are never touched. It still only happens after an
/// explicit consent dialog.
enum NotifyFeed {

    private static var supportDir: String {
        ("~/Library/Application Support/Houston" as String).expandingTildePath
    }

    static var scriptPath: String { supportDir + "/notify-feed.sh" }

    /// Quoted for `sh -c` — `Application Support` contains a space (the
    /// statusline feed's measured bug).
    static var hookCommand: String { "'" + scriptPath + "'" }

    /// Directory of per-event payload dumps.
    static var eventsDir: String { supportDir + "/notify" }

    /// The hook events Houston listens to.
    private static let hookEvents = ["Notification", "Stop"]

    /// Event files are `<pane-uuid>.<pid>.<epoch>.json` — a UUID has no dots,
    /// so the pane id is everything before the first one.
    private static var scriptSource: String {
        """
        #!/bin/sh
        # Houston notify feed — installed and managed by Houston.app.
        # Prints nothing; dumps each hook payload where Houston reads it.
        DIR="$HOME/Library/Application Support/Houston/notify"
        if [ -z "$HOUSTON_PANE" ]; then
          cat > /dev/null
          exit 0
        fi
        mkdir -p "$DIR"
        TMP="$DIR/.$HOUSTON_PANE.$$.tmp"
        cat > "$TMP" && mv -f "$TMP" "$DIR/$HOUSTON_PANE.$$.$(date +%s).json"
        exit 0
        """
    }

    // MARK: - Claude settings state

    /// Installed = our command appears under every hook event we need.
    static var isInstalled: Bool {
        guard let settings = readClaudeSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hookEvents.allSatisfy { event in
            groups(of: hooks, event: event).contains { groupHasOurCommand($0) }
        }
    }

    // MARK: - Install / restore

    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
        do {
            try scriptSource.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            return false
        }

        var settings = readClaudeSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            var eventGroups = groups(of: hooks, event: event)
            if !eventGroups.contains(where: { groupHasOurCommand($0) }) {
                eventGroups.append([
                    "hooks": [["type": "command", "command": hookCommand]]
                ])
            }
            hooks[event] = eventGroups
        }
        settings["hooks"] = hooks
        return writeClaudeSettings(settings)
    }

    /// Removes exactly our entries; the user's own hooks stay.
    @discardableResult
    static func restore() -> Bool {
        var settings = readClaudeSettings() ?? [:]
        guard var hooks = settings["hooks"] as? [String: Any] else { return true }
        for event in hookEvents {
            let remaining = groups(of: hooks, event: event)
                .filter { !groupHasOurCommand($0) }
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return writeClaudeSettings(settings)
    }

    private static func groups(
        of hooks: [String: Any], event: String
    ) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func groupHasOurCommand(_ group: [String: Any]) -> Bool {
        let entries = group["hooks"] as? [[String: Any]] ?? []
        return entries.contains { entry in
            let command = entry["command"] as? String
            return command == hookCommand || command == scriptPath
        }
    }

    private static func readClaudeSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: StatusLineFeed.claudeSettingsURL)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeClaudeSettings(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        return (try? data.write(
            to: StatusLineFeed.claudeSettingsURL, options: .atomic
        )) != nil
    }

    // MARK: - Event files

    struct Event {
        enum Kind {
            /// The `Notification` hook: permission request or waiting idle.
            case needsInput
            /// The `Stop` hook: the response turn ended.
            case finished
        }
        let paneID: String
        let kind: Kind
        let message: String
    }

    /// Sessions die with Houston — at launch everything on disk is stale.
    static func clearAllEvents() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir) else { return }
        for name in names {
            try? fm.removeItem(atPath: eventsDir + "/" + name)
        }
    }

    /// Reads and consumes every pending event, oldest first.
    static func drainEvents() -> [Event] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir) else { return [] }
        var events: [Event] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = eventsDir + "/" + name
            defer { try? fm.removeItem(atPath: path) }
            guard let dot = name.firstIndex(of: "."),
                  let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any]
            else { continue }
            let paneID = String(name[name.startIndex..<dot])
            switch obj["hook_event_name"] as? String {
            case "Notification":
                events.append(Event(
                    paneID: paneID,
                    kind: .needsInput,
                    message: obj["message"] as? String ?? "Claude needs your input"
                ))
            case "Stop":
                events.append(Event(paneID: paneID, kind: .finished, message: ""))
            default:
                continue
            }
        }
        return events
    }
}

// MARK: - Store

/// Turns hook events into attention state and native notifications.
///
/// An event for a pane the user is already looking at (its tab displayed,
/// app active) is dropped — they can see it. Anything else becomes a badge
/// on the project's sidebar row, a dot on the menubar item, and — packaged
/// builds only, `UNUserNotificationCenter` needs a bundle — a banner whose
/// click brings Houston up on that project.
@MainActor
final class NotifyStore: ObservableObject {
    static let shared = NotifyStore()

    struct Attention: Equatable {
        enum Kind: Equatable { case needsInput, finished }
        let kind: Kind
        let message: String
        let projectPath: String
        let tabID: UUID
    }

    /// Pending attention by pane id.
    @Published private(set) var attention: [String: Attention] = [:] {
        didSet { badgeChanged() }
    }

    /// Projects with any pending attention — the sidebar badge source.
    var attentionPaths: Set<String> { Set(attention.values.map(\.projectPath)) }

    func hasAttention(path: String) -> Bool {
        attention.values.contains { $0.projectPath == path }
    }

    func hasAttention(path: String, tab: UUID) -> Bool {
        attention.values.contains { $0.projectPath == path && $0.tabID == tab }
    }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        NotifyFeed.clearAllEvents()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in NotifyStore.shared.poll() }
        }
    }

    /// The user is looking at this project — its attention is spent.
    func markSeen(projectPath: String?) {
        guard let projectPath else { return }
        let remaining = attention.filter { $0.value.projectPath != projectPath }
        if remaining.count != attention.count { attention = remaining }
    }

    private func poll() {
        guard NotifyFeed.isInstalled else { return }
        for event in NotifyFeed.drainEvents() {
            handle(event)
        }
    }

    private func handle(_ event: NotifyFeed.Event) {
        guard let location = locate(paneID: event.paneID) else { return }
        // Visible and frontmost: the user is watching this pane — nothing to
        // announce.
        if isDisplayed(location) && NSApp.isActive {
            attention.removeValue(forKey: event.paneID)
            return
        }
        switch event.kind {
        case .needsInput:
            let new = Attention(
                kind: .needsInput,
                message: event.message,
                projectPath: location.path,
                tabID: location.tabID
            )
            // The hook re-fires while Claude keeps waiting — one banner per
            // distinct state, not one per reminder.
            let changed = attention[event.paneID] != new
            attention[event.paneID] = new
            if changed {
                EventFeed.shared.post(
                    .needsInput,
                    title: projectName(location.path),
                    detail: event.message,
                    projectPath: location.path
                )
                deliverBanner(
                    title: projectName(location.path),
                    body: event.message,
                    path: location.path
                )
            }
        case .finished:
            // The turn ended: any needs-input state is moot. Announce the
            // finish once, and not on the heels of a needs-input banner.
            let hadNeedsInput = attention[event.paneID]?.kind == .needsInput
            let new = Attention(
                kind: .finished,
                message: "Claude finished and is ready for you",
                projectPath: location.path,
                tabID: location.tabID
            )
            let changed = attention[event.paneID] != new
            attention[event.paneID] = new
            if changed && !hadNeedsInput {
                EventFeed.shared.post(
                    .finished,
                    title: projectName(location.path),
                    detail: new.message,
                    projectPath: location.path
                )
                deliverBanner(
                    title: projectName(location.path),
                    body: new.message,
                    path: location.path
                )
            }
        }
    }

    // MARK: - Pane geography

    private func locate(paneID: String) -> (path: String, tabID: UUID)? {
        for (path, tabs) in TerminalSessionManager.shared.tabs {
            for tab in tabs
            where tab.panes.contains(where: { $0.id.uuidString == paneID }) {
                return (path, tab.id)
            }
        }
        return nil
    }

    private func isDisplayed(_ location: (path: String, tabID: UUID)) -> Bool {
        let terminals = TerminalSessionManager.shared
        guard terminals.activeProjectPath == location.path else { return false }
        if let active = terminals.activeTabID { return active == location.tabID }
        return terminals.tabs[location.path]?.first?.id == location.tabID
    }

    private func projectName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Delivery

    /// `UNUserNotificationCenter` aborts without a bundle — debug builds
    /// (`swift run`) get badges only.
    private static var canBanner: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard canBanner else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func deliverBanner(title: String, body: String, path: String) {
        guard Self.canBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["path": path]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    private func badgeChanged() {
        (NSApp.delegate as? AppDelegate)?
            .setNeedsAttentionBadge(!attention.isEmpty)
    }
}
