import Foundation

/// Turns a captured native element + the user's instruction into the
/// prompt sent to the project's terminal. Native apps expose no source
/// metadata at runtime, so the prompt leans on the element's strings and
/// tells the agent to locate them first.
enum AXPromptComposer {

    /// No trailing newline — `PromptDelivery` appends it.
    static func compose(element: InspectedAXElement, instruction: String) -> String {
        var s = "In the running macOS app “\(element.app.name)”"
        if let bundleID = element.app.bundleID {
            s += " (\(bundleID))"
        }
        s += ", the user selected a \(element.roleDescription ?? InspectedAXElement.deAX(element.role))"
        if let title = element.title, !title.isEmpty {
            s += " titled “\(title)”"
        }
        if let identifier = element.identifier, !identifier.isEmpty {
            s += " (accessibility identifier `\(identifier)`)"
        }
        if let value = element.value, !value.isEmpty {
            s += " with value “\(value)”"
        }
        if let placeholder = element.placeholder, !placeholder.isEmpty {
            s += " with placeholder “\(placeholder)”"
        }
        if let windowTitle = element.windowTitle, !windowTitle.isEmpty {
            s += " in window “\(windowTitle)”"
        }
        let trail = element.ancestors.prefix(4)
            .map { ancestor in
                var part = InspectedAXElement.deAX(ancestor.role)
                if let title = ancestor.title, !title.isEmpty { part += " “\(title)”" }
                return part
            }
            .reversed()
        if !trail.isEmpty {
            s += ", under \(trail.joined(separator: " → "))"
        }
        if !element.enabled {
            s += ", currently disabled"
        }
        s += ". The app exposes no source metadata at runtime — locate this element"
        s += " in the codebase by searching for its title string or accessibility"
        s += " identifier before making changes. Requested change: \(instruction)"
        return s
    }
}
