import Combine
import Foundation

/// Live git state for the selected project — polled so the header badge and
/// panel track what agents are doing to the working tree in real time.
@MainActor
final class GitStatusStore: ObservableObject {
    @Published private(set) var info: GitInfo?

    private var path: String?
    private var timer: Timer?
    private var scanInFlight = false

    /// Point the store at a project (or nil to stop). Resets stale info so a
    /// previous project's state never flashes on the new one.
    func watch(_ newPath: String?) {
        guard newPath != path else { return }
        path = newPath
        info = nil
        refresh()
        if newPath == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
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
}
