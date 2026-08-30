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

/// A dev server Houston saw running that has since stopped — kept in the
/// sidebar as a gray "off" row so it can be inspected and relaunched.
/// One per project path; a new stop on the same project updates it.
struct RecentServer: Identifiable, Equatable {
    let projectPath: String
    let name: String
    let port: Int
    /// The live `DevServer.id` ("pid:port") this entry replaced — lets an
    /// open server sheet morph into the off page when its server dies.
    let lastLiveID: String

    var id: String { "off:\(projectPath)" }
}

