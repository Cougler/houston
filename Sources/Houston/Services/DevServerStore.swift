import Combine
import Foundation

/// Polling store for dev servers — an lsof scan on a slower cadence than the
/// session poll.
@MainActor
final class DevServerStore: ObservableObject {
    @Published private(set) var devServers: [DevServer] = []

    private var projectsDirs: [String] = HoustonSettings.defaults.projectsDirs
    private var timer: Timer?
    private var refreshInFlight = false

    func start() {
        reloadSettings()
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
        Task.detached(priority: .utility) {
            let dev = DevServerDetect.snapshot(projectsDirs: dirs)
            await MainActor.run {
                self.refreshInFlight = false
                self.devServers = dev
            }
        }
    }

    private func reloadSettings() {
        let s = HoustonSettings.read()
        if s.projectsDirs != projectsDirs {
            projectsDirs = s.projectsDirs
        }
    }
}
