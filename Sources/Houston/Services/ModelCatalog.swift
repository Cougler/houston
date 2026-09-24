import Foundation

/// The chat model menu's refresh channel — two sources, merged:
///
/// 1. **Curated** `models.json` from the repo (public GitHub raw, the same
///    channel `UpdateChecker` reads): the authoritative list — labels,
///    order, and args verified against the live CLI. A missing or
///    unparsable file leaves the shipped defaults as the base.
/// 2. **Discovered** from models.dev's open catalog (no auth): any
///    current-generation Claude / GPT chat model released AFTER the newest
///    curated entry and not already covered by one, so a brand-new model
///    shows up the day it lands with no JSON edit. Discovered entries sit
///    on top of the curated list (newest first); their args are the
///    provider's model ids, which both CLIs accept verbatim.
///
/// The merged result is cached under Application Support and re-applied
/// at launch, so a refresh sticks across restarts.
///
/// models.json schema (either key optional):
///
///     { "claude": [{"label": "Fable 5", "arg": "fable"}, …],
///       "openai": [{"label": "GPT-6 Astra", "arg": "gpt-6-astra"}, …] }
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    /// Bumped when an overlay lands — observers re-derive their menus.
    @Published private(set) var revision = 0
    @Published private(set) var refreshing = false
    @Published private(set) var lastError: String?

    static let curatedURL = URL(
        string: "https://raw.githubusercontent.com/Cougler/houston/main/models.json"
    )!
    static let discoveryURL = URL(string: "https://models.dev/api.json")!

    private static var cacheURL: URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/Houston/models.json" as NSString)
                .expandingTildeInPath)
    }

    private init() {
        // A previously merged list outlives the relaunch.
        if let data = try? Data(contentsOf: Self.cacheURL),
           let lists = Self.parseLists(data) {
            Self.install(lists)
            revision += 1
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastError = nil
        Task {
            defer { refreshing = false }
            // Curated base: the repo file, else whatever's in force
            // (shipped defaults or the last merge).
            var claude = ChatModelChoice.claude
            var openAI = ChatModelChoice.openAI
            var errors: [String] = []
            if let data = await Self.fetch(Self.curatedURL) {
                if let lists = Self.parseLists(data) {
                    if let c = lists.claude { claude = c }
                    if let o = lists.openAI { openAI = o }
                } else {
                    errors.append("models.json didn't parse")
                }
            } else {
                errors.append("models.json not reachable")
            }
            // Discovery: newer models the curated file hasn't caught up to.
            if let data = await Self.fetch(Self.discoveryURL),
               let catalog = (try? JSONSerialization.jsonObject(with: data))
                   as? [String: Any] {
                claude = Self.discovered(
                    in: catalog, provider: "anthropic", harness: .claude,
                    over: claude
                ) + claude
                openAI = Self.discovered(
                    in: catalog, provider: "openai", harness: .codex,
                    over: openAI
                ) + openAI
            } else {
                errors.append("models.dev not reachable")
            }
            Self.install((claude: claude, openAI: openAI))
            Self.writeCache(claude: claude, openAI: openAI)
            revision += 1
            lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        }
    }

    // MARK: - Curated

    private typealias Lists = (claude: [ChatModelChoice]?, openAI: [ChatModelChoice]?)

    private static func parseLists(_ data: Data) -> Lists? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any] else { return nil }
        func list(_ key: String, _ harness: ChatHarness) -> [ChatModelChoice]? {
            guard let raw = obj[key] as? [[String: Any]] else { return nil }
            let out: [ChatModelChoice] = raw.compactMap { dict in
                guard let label = dict["label"] as? String,
                      let arg = dict["arg"] as? String else { return nil }
                return ChatModelChoice(label: label, harness: harness, arg: arg)
            }
            return out.isEmpty ? nil : out
        }
        let lists: Lists = (list("claude", .claude), list("openai", .codex))
        return lists.claude == nil && lists.openAI == nil ? nil : lists
    }

    private static func install(_ lists: Lists) {
        if let c = lists.claude { ChatModelChoice.claude = c }
        if let o = lists.openAI { ChatModelChoice.openAI = o }
    }

    private static func writeCache(claude: [ChatModelChoice], openAI: [ChatModelChoice]) {
        func rows(_ list: [ChatModelChoice]) -> [[String: String]] {
            list.compactMap { m in m.arg.map { ["label": m.label, "arg": $0] } }
        }
        let obj: [String: Any] = ["claude": rows(claude), "openai": rows(openAI)]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Discovery (models.dev)

    private struct Found {
        let id: String
        let label: String
        let released: String  // ISO date, lexically sortable
    }

    /// Current-generation chat models from one models.dev provider that
    /// the curated list doesn't cover, released after its newest entry.
    /// Newest first.
    private static func discovered(
        in catalog: [String: Any], provider: String, harness: ChatHarness,
        over curated: [ChatModelChoice]
    ) -> [ChatModelChoice] {
        guard let models = (catalog[provider] as? [String: Any])?["models"]
            as? [String: Any] else { return [] }
        let all: [Found] = models.compactMap { id, raw in
            guard let dict = raw as? [String: Any],
                  let name = dict["name"] as? String,
                  let released = dict["release_date"] as? String,
                  dict["tool_call"] as? Bool == true,
                  let out = (dict["modalities"] as? [String: Any])?["output"]
                      as? [String], out.contains("text"),
                  isChatFamily(id, harness: harness)
            else { return nil }
            let label = harness == .claude
                ? name.replacingOccurrences(of: "Claude ", with: "")
                : name
            return Found(id: id, label: label, released: released)
        }
        func covered(_ m: Found) -> Bool {
            curated.contains {
                $0.arg == m.id || normalize($0.label) == normalize(m.label)
            }
        }
        // The curated frontier: the newest entry that resolves in the
        // catalog. Nothing resolves → a 90-day window stands in.
        let frontier = all.filter(covered).map(\.released).max()
            ?? ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-90 * 86_400)
            ).prefix(10).description
        return all
            .filter { !covered($0) && $0.released > frontier }
            .sorted { $0.released > $1.released }
            .map { ChatModelChoice(label: $0.label, harness: harness, arg: $0.id) }
    }

    /// The families each CLI runs as its chat model — not dated
    /// snapshots, not pro/mini/nano tiers, not realtime/image/embedding
    /// endpoints.
    private static func isChatFamily(_ id: String, harness: ChatHarness) -> Bool {
        let pattern: String
        switch harness {
        case .claude: pattern = #"^claude-(fable|opus|sonnet|haiku)-\d+(-\d+)?$"#
        case .codex: pattern = #"^gpt-\d+(\.\d+)?(-(?!pro$|mini$|nano$|chat$)[a-z]+)?$"#
        default: return false
        }
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
