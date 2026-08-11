import Foundation

/// Finds which coding agent (if any) is running inside each Houston pane.
///
/// **Why process-tree walking and not the `HOUSTON_PANE` env tag:** panes are
/// spawned through `login`, which is setuid, and macOS then refuses to report
/// the resulting process's environment — `ps eww <pane shell>` prints no env at
/// all. The tag is still stamped and still useful for correlating a *claude*
/// process (which does expose env), but it can't be relied on generally. Walking
/// pids is unconditional.
///
/// Panes are keyed by project path and each pane has a distinct working
/// directory, so an agent is matched back to its pane by cwd.
enum AgentDetect {

    /// Maps project path → the agent running in that directory under Houston.
    /// Directories with only a shell are absent.
    static func snapshot(paths: Set<String>) -> [String: CodingAgent] {
        guard !paths.isEmpty else { return [:] }
        let procs = ProcScan.table(withStartTimes: false)
        let me = ProcessInfo.processInfo.processIdentifier

        var result: [String: CodingAgent] = [:]
        for proc in procs.values {
            guard let agent = agentFor(command: proc.command) else { continue }
            guard ProcScan.isDescendant(proc.pid, of: me, in: procs) else { continue }
            guard let cwd = ProcScan.cwd(ofPid: proc.pid), paths.contains(cwd) else { continue }
            result[cwd] = agent
        }
        return result
    }

    /// Which launchable agents are actually installed, resolved through the
    /// user's login shell so PATH matches what a pane would see (Houston's
    /// own environment lacks Homebrew/npm paths when launched from the Dock).
    /// One shell spawn for all lookups. Blocks — call off the main thread.
    static func installedAgents() -> [CodingAgent] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let binaries = CodingAgent.launchable.compactMap(\.binary)
        let script = binaries
            .map { "command -v \($0) >/dev/null && echo \($0)" }
            .joined(separator: "; ")
        guard let out = ProcScan.run(shell, ["-l", "-c", script]) else { return [] }
        let found = Set(out.split(separator: "\n").map(String.init))
        return CodingAgent.launchable.filter { agent in
            agent.binary.map(found.contains) ?? false
        }
    }

    private static func agentFor(command: String) -> CodingAgent? {
        // Commands arrive as "claude", "-/opt/homebrew/bin/claude", or
        // "/usr/bin/env node .../codex". Take the first token, strip a leading
        // "-" (login shells) and any directory, then match the basename.
        guard var first = command.split(separator: " ").first.map(String.init) else {
            return nil
        }
        if first.hasPrefix("-") { first.removeFirst() }
        let name = (first as NSString).lastPathComponent
        return CodingAgent.from(binaryName: name)
    }
}
