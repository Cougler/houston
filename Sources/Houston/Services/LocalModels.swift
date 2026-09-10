import Foundation

/// Local inference engines for the chat composer — currently MLX Core
/// (its server binary is `mlx-serve`), an OpenAI-compatible MLX server
/// for Apple Silicon. Ollama and LM Studio are listed as coming soon.
///
/// Local models ride the codex harness: `codex app-server` is spawned
/// with a `model_providers.mlx` config override pointing at the server's
/// `/v1` endpoint, and the thread starts with `modelProvider: "mlx"` —
/// the same official escape hatch that will later cover Ollama and
/// LM Studio, since they all speak the same API.
///
/// Detection is filesystem + CLI: the binary is looked for in the app
/// bundle then on PATH, `mlx-serve list` supplies the models (chat-type
/// rows only — drafters and image models are filtered out), and the
/// server is started on demand right before a local turn.
@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    nonisolated static let mlxProviderID = "mlx"
    nonisolated static let mlxPort = 11234
    nonisolated static let mlxBaseURL = "http://localhost:11234/v1"
    nonisolated static let mlxBundledBinary =
        "/Applications/MLX Core.app/Contents/MacOS/mlx-serve"

    enum MLXState: Equatable {
        case unknown
        case notInstalled
        /// Installed; chat-capable model ids (full `org/repo` names).
        case installed(models: [String])
    }

    @Published private(set) var mlxState: MLXState = .unknown

    private var scanning = false
    private var serverStarting = false

    private init() {}

    var mlxModels: [String] {
        if case .installed(let models) = mlxState { return models }
        return []
    }

    /// Menu row text when there are no models to list.
    var mlxPlaceholder: String {
        switch mlxState {
        case .unknown: "MLX Core — detecting…"
        case .notInstalled: "MLX Core — Not installed"
        case .installed: "MLX Core — no chat models"
        }
    }

    /// Short menu label for a model id: the repo half of `org/repo`.
    nonisolated static func displayName(_ model: String) -> String {
        (model as NSString).lastPathComponent
    }

    /// Re-scan installed engines and their models. Single-flight; runs
    /// `mlx-serve list` off the main thread (it shells out and waits).
    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let state = Self.scanMLX()
            await MainActor.run {
                self.mlxState = state
                self.scanning = false
            }
        }
    }

    /// True once the MLX server answers on its port, starting
    /// `mlx-serve serve` first if nothing is listening. Models load on
    /// demand, so a fresh server is ready as soon as it binds.
    func ensureMLXRunning() async -> Bool {
        if await Self.probeMLX() { return true }
        if !serverStarting {
            serverStarting = true
            guard Self.launchMLXServer() else {
                serverStarting = false
                return false
            }
        }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await Self.probeMLX() {
                serverStarting = false
                return true
            }
        }
        serverStarting = false
        return false
    }

    // MARK: - MLX plumbing (all off the main actor)

    nonisolated private static func mlxBinary() -> String? {
        if FileManager.default.isExecutableFile(atPath: mlxBundledBinary) {
            return mlxBundledBinary
        }
        return AgentTransport.resolveBinary("mlx-serve")
    }

    /// `mlx-serve list` prints a NAME/TYPE/SIZE table (plus memory chatter
    /// before it); keep the rows whose TYPE is `chat`.
    nonisolated private static func scanMLX() -> MLXState {
        guard let binary = mlxBinary() else { return .notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .installed(models: []) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var models: [String] = []
        var inTable = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("NAME") { inTable = true; continue }
            guard inTable else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { continue }
            if cols[1] == "chat" { models.append(String(cols[0])) }
        }
        return .installed(models: models)
    }

    /// `localhost`, not `127.0.0.1` — same both-families rule as the dev
    /// server probes.
    nonisolated private static func probeMLX() async -> Bool {
        guard let url = URL(string: mlxBaseURL + "/models") else { return false }
        let request = URLRequest(url: url, timeoutInterval: 1.5)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    /// Detached child; the server deliberately outlives Houston — it's a
    /// user-level service other apps may be using too.
    nonisolated private static func launchMLXServer() -> Bool {
        guard let binary = mlxBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
