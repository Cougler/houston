import Foundation

/// MCP server health per project, for the status bar's MCP menu.
///
/// The statusline payload carries nothing about MCP, so this shells out to
/// `claude mcp list` — which actually connects to each configured server and
/// reports ✓/✗/needs-auth per line. That can take seconds, so checks run
/// detached with a single-flight guard per project, results are cached with
/// a timestamp, and `refreshIfStale` is the cheap entry point the UI calls
/// freely.
@MainActor
final class MCPStatusStore: ObservableObject {

    enum ServerState {
        case connected
        case needsAuth
        case failed
        case unknown
    }

    struct Server: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let state: ServerState
        /// The raw status text, for the menu row's help.
        let detail: String
    }

    struct Status: Equatable {
        var servers: [Server]
        var checkedAt: Date
        var checking: Bool
    }

    @Published private(set) var statuses: [String: Status] = [:]

    /// Server names with an OAuth flow currently open in the browser.
    @Published private(set) var authInFlight: Set<String> = []

    private var inFlight: Set<String> = []

    func refreshIfStale(path: String, maxAge: TimeInterval = 120) {
        if let status = statuses[path],
           Date().timeIntervalSince(status.checkedAt) < maxAge || status.checking {
            return
        }
        refresh(path: path)
    }

    func refresh(path: String) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        var current = statuses[path] ?? Status(servers: [], checkedAt: .distantPast, checking: true)
        current.checking = true
        statuses[path] = current

        Task.detached(priority: .utility) {
            let servers = Self.check(path: path)
            await MainActor.run {
                self.inFlight.remove(path)
                self.statuses[path] = Status(servers: servers, checkedAt: Date(), checking: false)
            }
        }
    }

    // MARK: - Auth

    /// Runs `claude mcp login <name>` — opens the browser OAuth flow and
    /// waits for it; the status re-checks when it finishes either way.
    func login(server: String, path: String) {
        guard !authInFlight.contains(server) else { return }
        authInFlight.insert(server)
        Task.detached(priority: .userInitiated) {
            _ = Self.runMCP(["login", server], path: path, timeout: 300)
            await MainActor.run {
                self.authInFlight.remove(server)
                self.refresh(path: path)
            }
        }
    }

    /// Clears a server's stored OAuth credentials.
    func logout(server: String, path: String) {
        Task.detached(priority: .userInitiated) {
            _ = Self.runMCP(["logout", server], path: path, timeout: 60)
            await MainActor.run { self.refresh(path: path) }
        }
    }

    // MARK: - The checks themselves (off-main)

    nonisolated private static func check(path: String) -> [Server] {
        guard let output = runMCP(["list"], path: path, timeout: 45) else { return [] }
        return parse(output)
    }

    /// Shells `claude mcp <args>` in the project directory and returns
    /// stdout, or nil if the process couldn't start.
    nonisolated private static func runMCP(
        _ args: [String], path: String, timeout: TimeInterval
    ) -> String? {
        // Server names carry spaces ("claude.ai Google Drive") — quote hard.
        let quoted = args
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell for the user's PATH — same reason AgentDetect uses one.
        process.arguments = ["-lc", "claude mcp \(quoted) 2>/dev/null"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        // Scrub session markers so the child isn't treated as a sub-session
        // (Houston itself often runs inside a claude session during dev).
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("CLAUDE_CODE_") }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // A hung server (or an abandoned OAuth tab) must not hang us forever.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        return String(data: data, encoding: .utf8)
    }

    /// Lines look like `name: command-or-url - ✓ Connected` (or ✗ Failed /
    /// needs authentication). Anything without the ` - ` separator is chrome.
    nonisolated private static func parse(_ output: String) -> [Server] {
        var servers: [Server] = []
        for line in output.split(separator: "\n") {
            guard let sep = line.range(of: " - ", options: .backwards),
                  let colon = line.firstIndex(of: ":"),
                  colon < sep.lowerBound else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let detail = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !detail.isEmpty else { continue }

            let lowered = detail.lowercased()
            let state: ServerState
            if lowered.contains("auth") {
                state = .needsAuth
            } else if detail.contains("✓") || lowered.contains("connected") {
                state = .connected
            } else if detail.contains("✗") || lowered.contains("fail") {
                state = .failed
            } else {
                state = .unknown
            }
            servers.append(Server(name: name, state: state, detail: detail))
        }
        return servers
    }
}
