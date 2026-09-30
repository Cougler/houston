import Combine
import Foundation

/// Live git state — the selected project's full `GitInfo` for the panel, and
/// a cheap per-row status for every open terminal's sidebar dot. Polled so
/// both track what agents are doing to working trees in real time.
@MainActor
final class GitStatusStore: ObservableObject {
    @Published private(set) var info: GitInfo?
    /// Dot state per terminal path.
    @Published private(set) var rowStatuses: [String: GitRowStatus] = [:]
    /// Linked worktrees per main checkout, for every watched repo.
    @Published private(set) var worktrees: [String: [GitWorktree]] = [:]

    /// The project `info` describes.
    private(set) var path: String?
    private var rowPaths: Set<String> = []
    private var timer: Timer?
    private var scanInFlight = false
    private var rowScanInFlight = false

    /// Begin the poll loop (idempotent).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshRows()
            }
        }
    }

    /// Point the panel at a project (or nil). Resets stale info so a previous
    /// project's state never flashes on the new one.
    func watch(_ newPath: String?) {
        guard newPath != path else { return }
        path = newPath
        info = nil
        refresh()
        refreshWorktrees()
    }

    /// The set of terminal paths whose rows need status dots.
    func watchRows(_ paths: Set<String>) {
        guard paths != rowPaths else { return }
        rowPaths = paths
        rowStatuses = rowStatuses.filter { paths.contains($0.key) }
        refreshRows()
    }

    func refresh() {
        guard let path, !scanInFlight else { return }
        scanInFlight = true
        Task.detached(priority: .utility) {
            let snapshot = GitDetect.snapshot(projectPath: path)
            await MainActor.run {
                self.scanInFlight = false
                // The selection may have moved while the scan ran.
                guard self.path == path else { return }
                if snapshot != self.info { self.info = snapshot }
            }
        }
    }

    /// The main checkout a worktree path belongs to (nil for anything
    /// that isn't a known linked worktree).
    func mainRepo(of path: String) -> String? {
        worktrees.first { $0.value.contains { $0.path == path } }?.key
    }

    /// Re-read worktrees now (after a create/remove), not on the next tick.
    func refreshWorktrees() {
        let repos = worktreeRepos()
        Task.detached(priority: .userInitiated) {
            let lists = Self.scanWorktrees(repos)
            await MainActor.run {
                if lists != self.worktrees { self.worktrees = lists }
            }
        }
    }

    /// Every main checkout behind the watched paths — a worktree path
    /// contributes its main repo, so a worktree's siblings list too.
    private func worktreeRepos() -> Set<String> {
        var paths = rowPaths
        if let path { paths.insert(path) }
        return Set(paths.map { GitWorktrees.mainRepo(ofWorktree: $0) ?? $0 })
    }

    /// Spawn-free (file reads only); repos without worktrees drop out.
    nonisolated private static func scanWorktrees(
        _ repos: Set<String>
    ) -> [String: [GitWorktree]] {
        var lists: [String: [GitWorktree]] = [:]
        for repo in repos {
            let linked = GitWorktrees.linked(of: repo)
            if !linked.isEmpty { lists[repo] = linked }
        }
        return lists
    }

    private func refreshRows() {
        guard !rowPaths.isEmpty, !rowScanInFlight else { return }
        rowScanInFlight = true
        let paths = rowPaths
        let repos = worktreeRepos()
        Task.detached(priority: .utility) {
            var statuses: [String: GitRowStatus] = [:]
            for p in paths {
                statuses[p] = GitDetect.rowStatus(projectPath: p)
            }
            let result = statuses
            let lists = Self.scanWorktrees(repos)
            await MainActor.run {
                self.rowScanInFlight = false
                if result != self.rowStatuses { self.rowStatuses = result }
                if lists != self.worktrees { self.worktrees = lists }
            }
        }
    }
}
