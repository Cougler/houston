import AppKit
import Foundation
import UserNotifications

/// A dated obligation Claude recorded via the `/track` skill — a client-secret
/// rotation, a cert renewal, a domain expiry. Anything with a future date the
/// user would otherwise have to remember.
struct TrackedItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// `YYYY-MM-DD` — the skill converts "in 24 months" to an absolute date.
    let due: String
    /// Project folder name under `~/Apps`, when tracked from one.
    let project: String?
    /// Days before `due` the item starts demanding attention; 30 when absent.
    let leadDays: Int?
    let notes: String?
    let done: Bool
    /// `YYYY-MM-DD` the item was marked done, when it is.
    let doneAt: String?
}

/// The tracked list behind the sidebar footer's bell.
///
/// The store is read-mostly: the `/track` skill (any Claude session, any
/// project) owns writes to `Application Support/Houston/tracked.json`, and
/// Houston polls the file's mtime. The two write paths Houston does have —
/// mark done, remove — go through the raw JSON dictionaries rather than the
/// parsed items, so fields the skill added and Houston doesn't know
/// (`repeatMonths`, `created`, …) survive the round trip.
@MainActor
final class TrackedStore: ObservableObject {

    static var fileURL: URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/Houston/tracked.json" as String)
                .expandingTildePath)
    }

    @Published private(set) var items: [TrackedItem] = []

    private var timer: Timer?
    private var lastModified: Date?
    /// Day the last reload ran — a date crossing midnight changes every
    /// countdown without the file changing, so the day rolling over forces one.
    private var lastDay: String = ""
    /// Items already announced this launch — the banner fires once per item,
    /// not once per poll.
    private var announced: Set<String> = []

    func start() {
        guard timer == nil else { return }
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload(force: false) }
        }
    }

    /// Active items, soonest due first.
    var active: [TrackedItem] {
        items.filter { !$0.done }
            .sorted { (daysUntil($0) ?? .max) < (daysUntil($1) ?? .max) }
    }

    /// Done items, most recently finished first — the panel's history.
    var doneItems: [TrackedItem] {
        items.filter(\.done)
            .sorted { ($0.doneAt ?? "") > ($1.doneAt ?? "") }
    }

    /// Overdue or inside the lead window — the bell badge count.
    var attentionCount: Int { active.filter(needsAttention).count }

    func needsAttention(_ item: TrackedItem) -> Bool {
        guard let days = daysUntil(item) else { return false }
        return days <= (item.leadDays ?? 30)
    }

    /// Calendar days from today to the item's due date; negative is overdue,
    /// nil an unparseable date.
    func daysUntil(_ item: TrackedItem) -> Int? {
        guard let due = Self.dayFormatter.date(from: item.due) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: due)
        ).day
    }

    static func countdown(days: Int?) -> String {
        guard let days else { return "no date" }
        switch days {
        case ..<(-1): return "\(-days) days overdue"
        case -1: return "1 day overdue"
        case 0: return "due today"
        case 1: return "due tomorrow"
        case ..<60: return "in \(days) days"
        default:
            let months = Int((Double(days) / 30.44).rounded())
            if months >= 24 && months % 12 == 0 { return "in \(months / 12) yr" }
            return "in \(months) mo"
        }
    }

    // MARK: - Write-backs

    /// Manual capture from the Tracked sheet — same store, same schema the
    /// /track skill writes, so the two entry paths are indistinguishable.
    /// Empty `project`/`notes` are omitted, not stored as "".
    func add(title: String, due: Date, project: String, leadDays: Int, notes: String) {
        let today = Self.dayFormatter.string(from: Date())
        let slugBase = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && out.hasSuffix("-") { return }
                out.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var id = slugBase.isEmpty ? "item" : slugBase
        var suffix = 2
        while items.contains(where: { $0.id == id }) {
            id = "\(slugBase)-\(suffix)"
            suffix += 1
        }
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "due": Self.dayFormatter.string(from: due),
            "leadDays": leadDays,
            "created": today,
            "done": false,
        ]
        if !project.isEmpty { dict["project"] = project }
        if !notes.isEmpty { dict["notes"] = notes }
        mutateRaw { $0.append(dict) }
    }

    func markDone(_ id: String) {
        mutateRaw { dicts in
            for index in dicts.indices where dicts[index]["id"] as? String == id {
                dicts[index]["done"] = true
                dicts[index]["doneAt"] = Self.dayFormatter.string(from: Date())
            }
        }
    }

    func remove(_ id: String) {
        mutateRaw { dicts in
            dicts.removeAll { $0["id"] as? String == id }
        }
    }

    /// Back to active — a done click was wrong, or the thing un-happened.
    func markUndone(_ id: String) {
        mutateRaw { dicts in
            for index in dicts.indices where dicts[index]["id"] as? String == id {
                dicts[index]["done"] = false
                dicts[index].removeValue(forKey: "doneAt")
            }
        }
    }

    /// Pushes the due date out — from the current due date when it's still
    /// ahead, from today when it already slipped past (snoozing an overdue
    /// item into the past would be no snooze at all).
    func postpone(_ id: String, byMonths months: Int = 0, byDays days: Int = 0) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let base = Self.dayFormatter.date(from: item.due).map { max($0, today) } ?? today
        var delta = DateComponents()
        delta.month = months
        delta.day = days
        guard let due = calendar.date(byAdding: delta, to: base) else { return }
        let dueString = Self.dayFormatter.string(from: due)
        mutateRaw { dicts in
            for index in dicts.indices where dicts[index]["id"] as? String == id {
                dicts[index]["due"] = dueString
            }
        }
        // It may re-enter its lead window later — let it announce again.
        announced.remove(id)
    }

    private func mutateRaw(_ mutate: (inout [[String: Any]]) -> Void) {
        let url = Self.fileURL
        var dicts = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            ?? []
        mutate(&dicts)
        guard let data = try? JSONSerialization.data(
            withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        reload(force: true)
    }

    // MARK: - Reload

    private func reload(force: Bool) {
        let url = Self.fileURL
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let today = Self.dayFormatter.string(from: Date())
        guard force || modified != lastModified || today != lastDay else { return }
        lastModified = modified
        lastDay = today

        let parsed = (try? Data(contentsOf: url)).map(Self.parse) ?? []
        if parsed != items { items = parsed }
        announceNewlyDue()
    }

    /// Hand-parsed rather than Codable so one malformed entry skips itself
    /// instead of blanking the whole list.
    private static func parse(_ data: Data) -> [TrackedItem] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data))
            as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let title = dict["title"] as? String,
                  let due = dict["due"] as? String else { return nil }
            return TrackedItem(
                id: id,
                title: title,
                due: due,
                project: dict["project"] as? String,
                leadDays: dict["leadDays"] as? Int,
                notes: dict["notes"] as? String,
                done: dict["done"] as? Bool ?? false,
                doneAt: dict["doneAt"] as? String
            )
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Announcements

    /// One announcement per item per launch when its lead window is open —
    /// the launch-time sweep is the reminder working, not noise. Every build
    /// posts to the bell's feed; the banner rides along in packaged builds
    /// only (`UNUserNotificationCenter` aborts without a bundle).
    private func announceNewlyDue() {
        for item in active where needsAttention(item) && !announced.contains(item.id) {
            announced.insert(item.id)
            EventFeed.shared.post(
                .trackedDue,
                title: item.title,
                detail: Self.countdown(days: daysUntil(item)).capitalizedFirst,
                projectPath: item.project.flatMap { project in
                    let path = NSHomeDirectory() + "/Apps/" + project
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default
                        .fileExists(atPath: path, isDirectory: &isDirectory)
                    return exists && isDirectory.boolValue ? path : nil
                }
            )
            guard Bundle.main.bundleIdentifier != nil else { continue }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = Self.countdown(days: daysUntil(item)).capitalizedFirst
            content.sound = .default
            // A banner click routes to the item's project when it maps to a
            // real directory — same userInfo contract as the needs-you banners.
            if let project = item.project {
                let path = NSHomeDirectory() + "/Apps/" + project
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    content.userInfo = ["path": path]
                }
            }
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "tracked-" + item.id,
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
