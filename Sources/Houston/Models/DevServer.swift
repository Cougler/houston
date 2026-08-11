import Foundation

/// One LISTEN-state TCP socket inside the user's dev port range.
struct DevServer: Identifiable, Equatable {
    let pid: Int32
    let port: Int
    let command: String
    let cwd: String?
    let project: String?
    let url: String

    var id: String { "\(pid):\(port)" }
}

