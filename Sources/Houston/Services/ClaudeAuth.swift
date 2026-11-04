import AppKit
import Foundation

/// Whether the Claude CLI is signed in (2026-10-23). The source of truth
/// is the CLI's own `claude auth status` (JSON: `loggedIn`, `authMethod`
/// — verified on 2.1.305), run with the same scrubbed environment and
/// shell PATH the chat spawns use, so the answer is the one Houston's
/// own processes would get. Checked at launch, on app activation, every
/// five minutes, every ten seconds while signed OUT (so finishing the
/// terminal login flips the UI on its own), and the moment a chat turn
/// fails with an auth-looking error. Drives the "Sign in again" offers:
/// the composer notice, the status bar pill, the chat's error card.
@MainActor
final class ClaudeAuthStore: ObservableObject {
    static let shared = ClaudeAuthStore()

    /// nil until the first check answers.
    @Published private(set) var loggedIn: Bool?
    @Published private(set) var authMethod: String?
    @Published private(set) var checking = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    struct Status: Equatable {
        let loggedIn: Bool
        let authMethod: String
    }

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        // Off the launch path's critical first seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = loggedIn == false ? 10 : 300
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// A chat turn failed in a way that reads as "not signed in" — check
    /// now so the rest of the UI agrees with the error.
    func noteAuthFailure() {
        refresh()
    }

    /// Open the CLI's login in the project's terminal; the store polls
    /// until the CLI reports signed in.
    func signIn(project: String) {
        PromptDelivery.login(.claude, project: project)
        // Poll fast from here even if the last answer was "signed in" (a
        // stale check) — `schedule` reads loggedIn, so force the short
        // interval until the next answer lands.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        Task.detached(priority: .utility) {
            let status = Self.probe()
            await MainActor.run { ClaudeAuthStore.shared.apply(status) }
        }
    }

    private func apply(_ status: Status?) {
        checking = false
        guard let status else { return }  // couldn't run the CLI: keep the last answer
        let was = loggedIn
        loggedIn = status.loggedIn
        authMethod = status.authMethod
        if was != status.loggedIn { schedule() }
    }

    /// `claude auth status` → parsed; nil when the CLI couldn't be run.
    nonisolated static func probe() -> Status? {
        guard let binary = AgentTransport.resolveBinary("claude") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "status"]
        process.environment = AgentTransport.spawnEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard var status = parse(data) else { return nil }
        // Credentials from the environment (an API key, a bearer token,
        // or a gateway base URL that authenticates upstream) make the CLI
        // work while `auth status` still says "none" — observed with the
        // Claude desktop app's gateway env (2026-10-23). Don't nag then.
        if !status.loggedIn {
            let env = process.environment ?? [:]
            let viaEnv = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]
                .contains { !(env[$0] ?? "").isEmpty }
            if viaEnv { status = Status(loggedIn: true, authMethod: "environment") }
        }
        return status
    }

    nonisolated static func parse(_ data: Data) -> Status? {
        // A chatty environment can print ahead of the JSON; take the
        // object from its first brace.
        guard let text = String(data: data, encoding: .utf8),
              let brace = text.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[brace...].utf8))
                as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else { return nil }
        return Status(loggedIn: loggedIn, authMethod: json["authMethod"] as? String ?? "")
    }
}
