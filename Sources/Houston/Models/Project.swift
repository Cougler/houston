import Foundation

struct Project: Identifiable, Equatable {
    let id: String       // absolute path
    let name: String
    let path: String
    /// Directory mtime — recency proxy for the empty state's quick-open row.
    let modifiedMs: Int64
}
