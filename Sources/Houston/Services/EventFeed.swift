import Foundation

/// One entry in the footer bell's notification feed.
struct HoustonEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A session is waiting on the user (permission prompt, idle).
        case needsInput
        /// A session's turn finished.
        case finished
        /// A tracked obligation entered its lead window (or is overdue).
        case trackedDue
        /// New commits landed on the watched project's branch.
        case commit
    }

    let id = UUID()
    let kind: Kind
    let date: Date
    /// Headline — usually the project or item name.
    let title: String
    let detail: String
    /// Clicking the row jumps here, when the event has a home.
    let projectPath: String?
}

/// The bell's feed: an in-session log of what happened while the user wasn't
/// looking. Sources post into it — NotifyStore's hook events, TrackedStore's
/// lead-window openings, the commit watch below — and the bell badges the
/// unread count until the flyout is opened.
///
/// Deliberately in-memory only: like Houston's sessions, the feed dies with
/// the app. It is history for *this* run, not a database.
@MainActor
final class EventFeed: ObservableObject {
    static let shared = EventFeed()

    /// Newest first, capped so a chatty day can't grow without bound.
    @Published private(set) var events: [HoustonEvent] = []
    @Published private(set) var unreadCount = 0

    private static let cap = 50

    func post(
        _ kind: HoustonEvent.Kind,
        title: String,
        detail: String,
        projectPath: String? = nil
    ) {
        events.insert(
            HoustonEvent(
                kind: kind,
                date: Date(),
                title: title,
                detail: detail,
                projectPath: projectPath
            ),
            at: 0
        )
        if events.count > Self.cap { events.removeLast(events.count - Self.cap) }
        unreadCount += 1
    }

    /// The flyout opened — everything in it has been seen.
    func markAllRead() {
        if unreadCount != 0 { unreadCount = 0 }
    }

    func clear() {
        events = []
        unreadCount = 0
    }

    /// "now", "5m ago", "2h ago", "yesterday".
    static func age(of event: HoustonEvent) -> String {
        let seconds = Int(Date().timeIntervalSince(event.date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "yesterday"
        }
    }

    // MARK: - Commit watch

    /// Last known HEAD sha and branch per project, fed by the git poll.
    private var lastHead: [String: String] = [:]
    private var lastBranch: [String: String] = [:]

    /// Called whenever the selected project's `GitInfo` refreshes. Posts a
    /// commit event when HEAD moves on the *same* branch — a branch switch
    /// also moves HEAD, and announcing that as "committed" would be wrong.
    /// Only the selected project is watched this deeply; that's the poll
    /// GitStatusStore already runs, not a new scan.
    func noteGit(path: String?, info: GitInfo?) {
        guard let path, let info, info.isRepo,
              let head = info.commits.first else { return }
        defer {
            lastHead[path] = head.sha
            lastBranch[path] = info.branchLabel
        }
        guard let previous = lastHead[path],
              previous != head.sha,
              lastBranch[path] == info.branchLabel,
              // The previous head still being in the log means history moved
              // forward (a commit or pull), not sideways (reset, rebase).
              info.commits.contains(where: { $0.sha == previous })
        else { return }
        // An unpushed head is a local commit; a pushed one arrived via pull.
        let verb = head.isUnpushed ? "Committed" : "New commits"
        post(
            .commit,
            title: (path as NSString).lastPathComponent,
            detail: "\(verb) on \(info.branchLabel): \(head.subject)",
            projectPath: path
        )
    }
}
