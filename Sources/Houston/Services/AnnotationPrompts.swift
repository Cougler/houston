import Foundation

/// Prompt composition for saved annotations: web captures re-resolve their
/// files at send time (they may have moved since the save); manual entries
/// send their comment as-is.
enum AnnotationPrompts {

    /// No trailing newline — `PromptDelivery` appends it.
    static func compose(_ annotation: Annotation, projectRoot: String) -> String {
        if let element = annotation.element {
            let (structure, styles, script) = ElementSourceResolver.resolveSources(
                for: element, projectRoot: projectRoot
            )
            return ElementSourceResolver.composePrompt(
                element: element,
                structure: structure,
                styleFiles: styles,
                scriptFile: script,
                instruction: annotation.comment
            )
        }
        return annotation.comment
    }

    /// One numbered prompt covering every given annotation. Each item keeps
    /// its full context (page URL / app) — items can span both kinds.
    static func composeBatch(_ annotations: [Annotation], projectRoot: String) -> String {
        guard annotations.count > 1 else {
            return annotations.first.map { compose($0, projectRoot: projectRoot) } ?? ""
        }
        var lines = ["Make the following \(annotations.count) changes:"]
        for (index, annotation) in annotations.enumerated() {
            lines.append("\(index + 1). " + compose(annotation, projectRoot: projectRoot))
        }
        return lines.joined(separator: "\n")
    }
}
