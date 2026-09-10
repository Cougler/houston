import Combine
import Foundation

/// Polls running claude sessions and the configured project folders.
@MainActor
final class ActiveSessionStore: ObservableObject {
    @Published private(set) var sessions: [ActiveSession] = []
    @Published private(set) var projectGroups: [ProjectGroup] = []
    @Published private(set) var projectsDirs: [String] = HoustonSettings.defaults.projectsDirs
    /// Single projects added directly to the sidebar (never expanded).
    @Published private(set) var pinnedProjects: [String] = []

    private var sessionTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshInFlight = false

    func start() {
        migrateFoldersToProjects()
        reloadSettings()
        refresh()
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        settingsTimer?.invalidate()
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadSettings() }
        }
    }

    /// Call after writing settings so a folder add/remove shows up now, not
    /// on the next 5s settings tick.
    func settingsChanged() {
        reloadSettings()
    }

    /// One scan in flight at a time — a slow `ps`/transcript pass must not
    /// stack a second one on the next tick.
    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let dirs = projectsDirs
        Task.detached(priority: .utility) {
            let snapshot = ProcessDetect.snapshot()
            let groups = dirs.map { dir in
                ProjectGroup(
                    path: dir,
                    name: (dir as NSString).lastPathComponent,
                    projects: ProjectList.scan(projectsDir: dir)
                )
            }
            await MainActor.run {
                self.refreshInFlight = false
                self.sessions = snapshot
                self.projectGroups = groups
            }
        }
    }

    /// Folder groups are gone (2026-09-09): anything added to the projects
    /// list IS a project — one row, never expanded into subdirectories.
    /// One-time fold of the old `projectsDirs` entries into
    /// `pinnedProjects`, order kept, deduped. Server attribution still
    /// works: pinned matching is prefix-based, so a dev server inside a
    /// former group attributes to the group's row.
    private func migrateFoldersToProjects() {
        var s = HoustonSettings.read()
        guard !s.projectsDirs.isEmpty else { return }
        for dir in s.projectsDirs where !s.pinnedProjects.contains(dir) {
            s.pinnedProjects.append(dir)
        }
        s.projectsDirs = []
        HoustonSettings.write(s)
    }

    private func reloadSettings() {
        let s = HoustonSettings.read()
        if s.projectsDirs != projectsDirs {
            projectsDirs = s.projectsDirs
            refresh()
        }
        if s.pinnedProjects != pinnedProjects {
            pinnedProjects = s.pinnedProjects
        }
    }
}
