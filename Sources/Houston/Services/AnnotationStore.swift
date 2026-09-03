import CryptoKit
import Foundation

/// One saved comment on an inspected element — a change the user wants
/// eventually, without prompting the agent right now. The element is a
/// web-preview DOM capture; nil means a manual entry. (The menubar App
/// Inspector's AX captures were removed 2026-09-03 — entries saved by it
/// keep their comment and parse as manual entries.)
struct Annotation: Identifiable, Equatable {
    let id: String
    /// ISO-8601 creation timestamp.
    let created: String
    let comment: String
    let done: Bool
    /// Already sent to the terminal (send-one or send-all) — kept visible
    /// so the list shows what's in flight vs still waiting.
    let sent: Bool
    /// The captured payload, verbatim — "send later" composes the same
    /// prompt the live flow would have, re-resolving files at send time.
    let element: InspectedElement?
    let pageURL: String

    /// "<button.cta>" — the row headline.
    var summaryText: String {
        if let element { return "<\(element.summary)>" }
        return ""
    }
}

/// Per-project comment list behind the preview window's annotations panel.
///
/// Follows `TrackedStore`'s shape: mtime-polled JSON under Application
/// Support, hand-parsed so one malformed entry skips itself, write-backs
/// through the raw dictionaries so fields this build doesn't know survive
/// the round trip. Keyed by project path (not port/pid), so the list
/// survives server restarts and Houston relaunches; two windows on the same
/// project reconcile through the poll.
@MainActor
final class AnnotationStore: ObservableObject {

    let projectPath: String
    let fileURL: URL

    @Published private(set) var items: [Annotation] = []

    private var timer: Timer?
    private var lastModified: Date?

    init(projectPath: String) {
        self.projectPath = projectPath
        // Slug for the human, hash for uniqueness — two projects can share
        // a folder name.
        let slug = (projectPath as NSString).lastPathComponent
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && out.hasSuffix("-") { return }
                out.append(ch)
            }
        let digest = SHA256.hash(data: Data(projectPath.utf8))
        let hash8 = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        let dir = ("~/Library/Application Support/Houston/annotations" as String)
            .expandingTildePath
        fileURL = URL(fileURLWithPath: dir)
            .appendingPathComponent("\(slug.isEmpty ? "project" : slug)-\(hash8).json")
    }

    func start() {
        guard timer == nil else { return }
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload(force: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Not yet done — the todo list proper, oldest first (pin numbers are
    /// positions in this list).
    var open: [Annotation] { items.filter { !$0.done } }
    var doneItems: [Annotation] { items.filter(\.done) }

    // MARK: - Write-backs

    func add(comment: String, element: InspectedElement) {
        guard let elementDict = Self.encode(element) else { return }
        add(comment: comment, payloadKey: "element", payload: elementDict, pageURL: element.pageURL)
    }

    /// A manual entry typed straight into the changes page — no captured
    /// element, just the request.
    func add(comment: String) {
        add(comment: comment, payloadKey: nil, payload: nil, pageURL: "")
    }

    private func add(
        comment: String, payloadKey: String?, payload: [String: Any]?, pageURL: String
    ) {
        var dict: [String: Any] = [
            "id": UUID().uuidString,
            "created": ISO8601DateFormatter().string(from: Date()),
            "comment": comment,
            "done": false,
            "sent": false,
        ]
        if let payloadKey, let payload { dict[payloadKey] = payload }
        if !pageURL.isEmpty { dict["pageURL"] = pageURL }
        mutateRaw { $0.append(dict) }
    }

    func updateComment(_ id: String, comment: String) {
        mutateRaw { dicts in
            for index in dicts.indices where dicts[index]["id"] as? String == id {
                dicts[index]["comment"] = comment
            }
        }
    }

    func markDone(_ id: String) { setFlag(id, key: "done", to: true) }
    func markUndone(_ id: String) { setFlag(id, key: "done", to: false) }
    func markSent(_ id: String) { setFlag(id, key: "sent", to: true) }

    func remove(_ id: String) {
        mutateRaw { dicts in
            dicts.removeAll { $0["id"] as? String == id }
        }
    }

    private func setFlag(_ id: String, key: String, to value: Bool) {
        mutateRaw { dicts in
            for index in dicts.indices where dicts[index]["id"] as? String == id {
                dicts[index][key] = value
            }
        }
    }

    private func mutateRaw(_ mutate: (inout [[String: Any]]) -> Void) {
        var obj = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        var dicts = obj["items"] as? [[String: Any]] ?? []
        mutate(&dicts)
        obj["items"] = dicts
        obj["projectPath"] = projectPath
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        reload(force: true)
    }

    // MARK: - Reload

    private func reload(force: Bool) {
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard force || modified != lastModified else { return }
        lastModified = modified
        let parsed = (try? Data(contentsOf: fileURL)).map(Self.parse) ?? []
        if parsed != items { items = parsed }
    }

    private static func parse(_ data: Data) -> [Annotation] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["items"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let comment = dict["comment"] as? String else { return nil }
            // Nil element is legal: a manual entry typed into the changes
            // page (or an old App Inspector capture, kept as its comment).
            let element: InspectedElement? =
                (dict["element"] as? [String: Any]).flatMap(decode)
            return Annotation(
                id: id,
                created: dict["created"] as? String ?? "",
                comment: comment,
                done: dict["done"] as? Bool ?? false,
                sent: dict["sent"] as? Bool ?? false,
                element: element,
                pageURL: dict["pageURL"] as? String ?? element?.pageURL ?? ""
            )
        }
    }

    private static func encode(_ value: some Encodable) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func decode<T: Decodable>(_ dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// One store instance per project, shared by every consumer (web preview
/// windows, the main window's header + sheet) — a save
/// anywhere updates every badge immediately instead of waiting out the
/// file poll.
@MainActor
enum AnnotationStores {
    private static var cache: [String: AnnotationStore] = [:]

    static func store(for projectPath: String) -> AnnotationStore {
        if let hit = cache[projectPath] { return hit }
        let store = AnnotationStore(projectPath: projectPath)
        store.start()
        cache[projectPath] = store
        return store
    }

    /// Every project with a saved task file on disk — the All Tasks sheet's
    /// data. Each file records its `projectPath`, so the scan needs no
    /// filename reverse-engineering.
    static func allStores() -> [AnnotationStore] {
        let dir = ("~/Library/Application Support/Houston/annotations" as String)
            .expandingTildePath
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".json") {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let path = obj["projectPath"] as? String else { continue }
            _ = store(for: path)
        }
        return cache.values.sorted {
            ($0.projectPath as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(
                    ($1.projectPath as NSString).lastPathComponent
                ) == .orderedAscending
        }
    }
}
