import Foundation

/// The chat model menu's refresh channel. The composer's Claude / OpenAI
/// lists ship as defaults in the binary (`ChatModelChoice.claude` /
/// `.openAI`); "Refresh Model List" fetches `models.json` from the repo —
/// the same public GitHub channel `UpdateChecker` reads — and overlays
/// them, so a new model is a one-line JSON edit on main, no app update.
/// The fetched file is cached under Application Support and re-applied at
/// launch, so a refresh sticks across restarts.
///
/// Schema (either key optional; a missing or empty list leaves the
/// shipped default alone):
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

    static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/Cougler/houston/main/models.json"
    )!

    private static var cacheURL: URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/Houston/models.json" as NSString)
                .expandingTildeInPath)
    }

    private init() {
        // A previously fetched list outlives the relaunch.
        if let data = try? Data(contentsOf: Self.cacheURL), Self.apply(data) {
            revision += 1
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastError = nil
        Task {
            defer { refreshing = false }
            do {
                var request = URLRequest(url: Self.remoteURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    lastError = "Model list not found"
                    return
                }
                guard Self.apply(data) else {
                    lastError = "Model list didn't parse"
                    return
                }
                try? FileManager.default.createDirectory(
                    at: Self.cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: Self.cacheURL, options: .atomic)
                revision += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Overlays whichever lists the JSON carries; false = nothing usable.
    private static func apply(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any] else { return false }
        func list(_ key: String, _ harness: ChatHarness) -> [ChatModelChoice]? {
            guard let raw = obj[key] as? [[String: Any]] else { return nil }
            let out: [ChatModelChoice] = raw.compactMap { dict in
                guard let label = dict["label"] as? String,
                      let arg = dict["arg"] as? String else { return nil }
                return ChatModelChoice(label: label, harness: harness, arg: arg)
            }
            return out.isEmpty ? nil : out
        }
        var applied = false
        if let claude = list("claude", .claude) {
            ChatModelChoice.claude = claude
            applied = true
        }
        if let openAI = list("openai", .codex) {
            ChatModelChoice.openAI = openAI
            applied = true
        }
        return applied
    }
}
