import AppKit

/// A third-party cloud model provider chats run through codex's custom
/// provider mechanism — the same rail the local MLX engine rides: the
/// spawn carries `model_providers.<id>.*` config overrides and the
/// thread starts with `modelProvider`.
///
/// codex only speaks the OpenAI Responses wire API (`wire_api = "chat"`
/// is rejected at load since codex 0.14x), so a provider is `compatible`
/// only if its OpenAI-compat surface serves `/responses`. Probed
/// 2026-09-14: xAI answers 422 on an empty POST there (endpoint real),
/// Gemini 404s (chat completions only), DeepSeek is a catch-all 401
/// (unknowable without a key — wired optimistically).
struct ChatProvider: Identifiable {
    struct ProviderModel {
        let label: String
        let arg: String
    }

    /// codex `model_providers` key, and the key-store key.
    let id: String
    let name: String
    /// Which harness runs this provider's models. Grok/DeepSeek ride the
    /// codex custom-provider rail; Gemini has its own ACP harness.
    var harness: ChatHarness = .codex
    let baseURL: String
    /// Env var codex reads the API key from (`env_key`) — set on the
    /// app-server spawn, never written to any config file.
    let envKey: String
    /// The provider's key console — the browser side of sign-in.
    let consoleURL: String
    let compatible: Bool
    /// True when the provider's CLI offers a real browser OAuth Houston
    /// can drive (Gemini via ACP `authenticate`) — shown alongside the
    /// key-paste path.
    var oauth: Bool = false
    let models: [ProviderModel]

    /// Grok Build (`grok agent stdio`) — xAI's official ACP coding agent.
    /// Its own CLI owns auth (browser OAuth via `grok login`) and the
    /// sandbox, exactly like the Gemini path.
    static let grok = ChatProvider(
        id: "xai", name: "Grok",
        harness: .grok,
        baseURL: "https://api.x.ai/v1",
        envKey: "XAI_API_KEY",
        consoleURL: "https://console.x.ai",
        compatible: true,
        oauth: true,
        models: [
            ProviderModel(label: "Grok 4", arg: "grok-4"),
            ProviderModel(label: "Grok 4 Fast", arg: "grok-4-fast"),
            ProviderModel(label: "Grok Code Fast", arg: "grok-code-fast-1"),
        ]
    )

    static let gemini = ChatProvider(
        id: "gemini", name: "Gemini",
        harness: .gemini,
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        envKey: "GEMINI_API_KEY",
        consoleURL: "https://aistudio.google.com/apikey",
        // Gemini runs on its own ACP harness (the gemini CLI), not the
        // codex Responses rail — so it's fully usable, not gated.
        compatible: true,
        oauth: true,
        models: [
            ProviderModel(label: "Gemini 3 Pro", arg: "gemini-3-pro-preview"),
            ProviderModel(label: "Gemini 2.5 Pro", arg: "gemini-2.5-pro"),
            ProviderModel(label: "Gemini 2.5 Flash", arg: "gemini-2.5-flash"),
        ]
    )

    static let deepseek = ChatProvider(
        id: "deepseek", name: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        envKey: "DEEPSEEK_API_KEY",
        consoleURL: "https://platform.deepseek.com/api_keys",
        compatible: true,
        models: [
            ProviderModel(label: "DeepSeek Chat", arg: "deepseek-chat"),
            ProviderModel(label: "DeepSeek Reasoner", arg: "deepseek-reasoner"),
        ]
    )

    static let cloud: [ChatProvider] = [grok, gemini, deepseek]

    static func by(id: String) -> ChatProvider? {
        cloud.first { $0.id == id }
    }
}

/// Per-provider API keys and the sign-in flows. Keys live in a 0600 file
/// under Application Support (the same convention the CLIs themselves
/// use for their auth files) and reach codex as env vars on the spawn.
@MainActor
final class ProviderAuthStore: ObservableObject {
    static let shared = ProviderAuthStore()

    @Published private(set) var keys: [String: String] = [:]

    /// The provider whose API-key dialog is up — set by `beginSignIn`,
    /// rendered by the main window's modal layer (the native NSAlert this
    /// replaced looked nothing like Houston's dialogs).
    @Published var keyPrompt: ChatProvider?

    private static var fileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Houston/provider-keys.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            keys = stored
        }
        // CLI-owned OAuth (gemini, grok) leaves a credential cache — count
        // it as signed in. Derived, never saved to our file.
        if keys[ChatProvider.gemini.id] == nil,
           FileManager.default.fileExists(
               atPath: NSHomeDirectory() + "/.gemini/oauth_creds.json") {
            keys[ChatProvider.gemini.id] = "oauth"
        }
        if keys[ChatProvider.grok.id] == nil,
           FileManager.default.fileExists(
               atPath: NSHomeDirectory() + "/.grok/auth.json") {
            keys[ChatProvider.grok.id] = "oauth"
        }
    }

    func signedIn(_ id: String) -> Bool {
        keys[id]?.isEmpty == false
    }

    func key(for id: String) -> String? {
        keys[id].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setKey(_ key: String, for id: String) {
        keys[id] = key
        save()
    }

    func clearKey(for id: String) {
        keys.removeValue(forKey: id)
        save()
    }

    private func save() {
        let url = Self.fileURL
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(keys) else { return }
        // NOT `write(options: .atomic)` + chmod after: the atomic write
        // creates its temp file under the default umask (0644), so the
        // plaintext keys were world-readable for a window on every save.
        // Create the replacement 0600 from the first byte, then swap it in.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".provider-keys-\(UUID().uuidString).tmp")
        guard fm.createFile(
            atPath: temp.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        _ = try? fm.replaceItemAt(url, withItemAt: temp)
        try? fm.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// API-key sign-in: the browser opens at the provider's console for
    /// the actual login; the in-window dialog stays up so the minted key
    /// has a place to land when the user comes back.
    func beginSignIn(_ provider: ChatProvider) {
        openConsole(provider)
        keyPrompt = provider
    }

    func openConsole(_ provider: ChatProvider) {
        if let url = URL(string: provider.consoleURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// OpenAI is codex's own OAuth. Run `codex login` in a Houston
    /// terminal (NOT a headless Process): the terminal has the user's
    /// full shell env — codex is a node shim that dies without it — and
    /// the flow's output is visible instead of silently swallowed.
    func signInOpenAI() {
        NotificationCenter.default.post(
            name: .houstonRunLoginCommand, object: nil,
            userInfo: ["command": "codex login"]
        )
    }

    func signOutOpenAI() {
        NotificationCenter.default.post(
            name: .houstonRunLoginCommand, object: nil,
            userInfo: ["command": "codex logout"]
        )
    }

    /// Codex holds its own credential; its auth file is the truth.
    var codexSignedIn: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.codex/auth.json")
    }

    /// Claude's /login flow needs the CLI's own TUI (browser OAuth with a
    /// paste-back code) — run it in a Houston terminal.
    func signInClaude() {
        NotificationCenter.default.post(
            name: .houstonRunLoginCommand, object: nil,
            userInfo: ["command": "claude /login"]
        )
    }

    /// Retained while Google's OAuth round-trip is in flight — a running
    /// Process must be held or it deallocates under the flow.
    private var geminiAuthProcess: Process?

    /// Gemini's REAL browser OAuth, driven through the CLI's ACP surface
    /// (verified live 2026-09-14): initialize → `authenticate` with
    /// `oauth-personal` opens Google's login in the browser and answers
    /// only when the user finishes there. The CLI caches the credential
    /// itself (~/.gemini), so the gemini CLI is signed in everywhere.
    func signInGemini() {
        guard let binary = AgentTransport.resolveBinary("gemini") else {
            let alert = NSAlert()
            alert.messageText = "Gemini CLI not installed"
            alert.informativeText =
                "Houston drives Google's sign-in through the Gemini CLI. "
                + "Install it first:  brew install gemini-cli"
            alert.runModal()
            return
        }
        geminiAuthProcess?.terminate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--acp"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization
                    .jsonObject(with: Data(line)) as? [String: Any],
                    (obj["id"] as? Int) == 1
                else { continue }
                let succeeded = obj["error"] == nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if succeeded {
                        self.setKey("oauth", for: ChatProvider.gemini.id)
                    }
                    self.geminiAuthProcess?.terminate()
                    self.geminiAuthProcess = nil
                }
                return
            }
        }
        geminiAuthProcess = process
        guard (try? process.run()) != nil else {
            geminiAuthProcess = nil
            return
        }
        func send(_ line: String) {
            stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        }
        send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}"#)
        send(#"{"jsonrpc":"2.0","id":1,"method":"authenticate","params":{"methodId":"oauth-personal"}}"#)
    }
}
