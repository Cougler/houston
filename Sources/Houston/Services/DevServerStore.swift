import Combine
import Foundation

/// How a dev server answered its last HTTP probe.
enum ServerHealth {
    /// Responded (or is alive speaking something other than HTTP).
    case healthy
    /// Reachable but erroring — a 5xx from the app.
    case degraded
    /// The socket is listed but nothing answers — refused or hung.
    case down
}

/// Polling store for dev servers — an lsof scan on a slower cadence than the
/// session poll, plus a gentle HTTP health probe per server.
@MainActor
final class DevServerStore: ObservableObject {
    @Published private(set) var devServers: [DevServer] = []
    /// Probe verdicts by `DevServer.id`; absent until a first probe lands.
    @Published private(set) var health: [String: ServerHealth] = [:]
    /// Servers that have stopped since Houston saw them — the sidebar's
    /// gray "off" rows. One per project path, persisted in settings so the
    /// list survives relaunches.
    @Published private(set) var recents: [RecentServer] = []

    private var projectsDirs: [String] = HoustonSettings.defaults.projectsDirs
    private var pinnedProjects: [String] = HoustonSettings.defaults.pinnedProjects
    private var timer: Timer?
    private var refreshInFlight = false
    /// Probes re-run only after this long — a HEAD every scan tick would
    /// keep dev servers (Next.js especially) permanently busy re-rendering.
    private let probeInterval: TimeInterval = 30
    private var probedAt: [String: Date] = [:]
    private var probeInFlight = false

    func start() {
        reloadSettings()
        loadRecents()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSettings()
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let dirs = projectsDirs
        let pinned = pinnedProjects
        Task.detached(priority: .utility) {
            let dev = DevServerDetect.snapshot(projectsDirs: dirs, pinnedProjects: pinned)
            await MainActor.run {
                self.refreshInFlight = false
                // Only servers attributable to a project. Claude Code spawns
                // its own node listeners (MCP bridges etc.) in the dev port
                // range — from a home shell those have no project and were
                // cluttering the section.
                let previous = self.devServers
                self.devServers = dev.filter { $0.project != nil }
                self.updateRecents(previous: previous)
                let ids = Set(dev.map(\.id))
                self.health = self.health.filter { ids.contains($0.key) }
                self.probedAt = self.probedAt.filter { ids.contains($0.key) }
                self.probeStale()
            }
        }
    }

    /// Probes servers whose verdict is missing or older than `probeInterval`.
    /// Runs on the main actor — the network awaits suspend, they don't block.
    private func probeStale() {
        guard !probeInFlight else { return }
        let now = Date()
        let stale = devServers.filter { server in
            probedAt[server.id].map { now.timeIntervalSince($0) > probeInterval } ?? true
        }
        guard !stale.isEmpty else { return }
        probeInFlight = true
        Task {
            for server in stale {
                let verdict = await Self.probe(port: server.port)
                health[server.id] = verdict
                probedAt[server.id] = Date()
            }
            probeInFlight = false
        }
    }

    /// HEAD to localhost — cheap enough not to wake a dev server's compiler,
    /// and enough to tell alive from erroring from hung.
    ///
    /// `localhost`, NOT `127.0.0.1`: node dev servers routinely bind only the
    /// IPv6 loopback (`::1`), and probing the IPv4 address alone reported a
    /// perfectly healthy server as down. The hostname resolves both families
    /// and connects on whichever answers.
    private nonisolated static func probe(port: Int) async -> ServerHealth {
        guard let url = URL(string: "http://localhost:\(port)/") else { return .healthy }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .healthy }
            return http.statusCode >= 500 ? .degraded : .healthy
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost:
                // The listener exists (lsof saw it) but nothing accepts on
                // either loopback — genuinely down.
                return .down
            case .timedOut:
                // Accepted but slow — a dev server compiling, not a corpse.
                return .degraded
            default:
                // Connected but not speaking HTTP (a websocket, a DB) —
                // alive, just not probeable.
                return .healthy
            }
        } catch {
            return .healthy
        }
    }

    private func reloadSettings() {
        let s = HoustonSettings.read()
        if s.projectsDirs != projectsDirs {
            projectsDirs = s.projectsDirs
        }
        if s.pinnedProjects != pinnedProjects {
            pinnedProjects = s.pinnedProjects
        }
    }

    // MARK: - Recents (stopped servers)

    /// The recent entry a sheet id addresses — its own off-id, or the live
    /// "pid:port" id it replaced (so an open server sheet survives the stop).
    func recent(matching sid: String) -> RecentServer? {
        recents.first { $0.id == sid || $0.lastLiveID == sid }
    }

    /// "Remove from Sidebar" — temporary by design: the next time a server
    /// runs (and stops) in that project, the row comes back.
    func removeRecent(_ id: String) {
        guard recents.contains(where: { $0.id == id }) else { return }
        recents.removeAll { $0.id == id }
        saveRecents()
    }

    /// Servers in the last snapshot that vanished from this one become
    /// recents; a project whose server is live again drops its recent row.
    private func updateRecents(previous: [DevServer]) {
        let liveIDs = Set(devServers.map(\.id))
        let livePaths = Set(devServers.compactMap(\.cwd))
        var next = recents
        for gone in previous where !liveIDs.contains(gone.id) {
            guard let cwd = gone.cwd, let project = gone.project else { continue }
            next.removeAll { $0.projectPath == cwd }
            next.append(RecentServer(
                projectPath: cwd, name: project, port: gone.port, lastLiveID: gone.id
            ))
        }
        next.removeAll { livePaths.contains($0.projectPath) }
        if next != recents {
            recents = next.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            saveRecents()
        }
    }

    private func loadRecents() {
        recents = HoustonSettings.read().recentServers.compactMap { dict in
            guard let path = dict["path"], let name = dict["name"],
                  let port = dict["port"].flatMap(Int.init) else { return nil }
            return RecentServer(
                projectPath: path, name: name, port: port,
                lastLiveID: dict["lastLiveID"] ?? ""
            )
        }
    }

    private func saveRecents() {
        var s = HoustonSettings.read()
        s.recentServers = recents.map {
            [
                "path": $0.projectPath,
                "name": $0.name,
                "port": String($0.port),
                "lastLiveID": $0.lastLiveID,
            ]
        }
        HoustonSettings.write(s)
    }
}
