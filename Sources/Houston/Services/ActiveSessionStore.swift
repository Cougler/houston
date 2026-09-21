import Combine
import Foundation

/// Polls running claude sessions and the configured project folders.
@MainActor
final class ActiveSessionStore: ObservableObject {
    @Published private(set) var sessions: [ActiveSession] = []
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
        Task.detached(priority: .utility) {
            let snapshot = ProcessDetect.snapshot()
            await MainActor.run {
                self.refreshInFlight = false
                self.sessions = snapshot
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
        // Only folders the user actually persisted migrate — the raw JSON
        // must carry the key. `read()`'s defaults include ~/Apps, and
        // folding those in auto-pinned a fresh install's whole Apps
        // folder as a "project" before the user ever added one.
        guard let data = try? Data(contentsOf: HoustonSettings.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let dirs = json["projectsDirs"] as? [String], !dirs.isEmpty
        else { return }
        var s = HoustonSettings.read()
        for dir in dirs where !s.pinnedProjects.contains(dir) {
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
