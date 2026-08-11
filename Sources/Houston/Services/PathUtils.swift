import Foundation

extension String {
    /// `~` -> `$HOME`, leaving other path components untouched.
    var expandingTildePath: String {
        (self as NSString).expandingTildeInPath
    }
}
