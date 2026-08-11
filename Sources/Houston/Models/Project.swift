import Foundation

struct Project: Identifiable, Equatable {
    let id: String       // absolute path
    let name: String
    let path: String
    /// Directory mtime — recency proxy for the empty state's quick-open row.
    let modifiedMs: Int64
}

/// One parent folder from settings and the projects inside it — a collapsible
/// group in the sidebar's Projects section.
struct ProjectGroup: Equatable {
    let path: String
    let name: String
    let projects: [Project]
}
