import AppKit
import SwiftUI

/// Contents of the App Inspector's popover: the captured element's AX
/// facts, a project picker, and the instruction field. Visual twin of the
/// web preview's InspectorPopover.
struct AXInspectPopover: View {
    let element: InspectedAXElement
    let projects: [Project]
    let onSend: (_ instruction: String, _ projectPath: String) -> Void
    let onSave: (_ instruction: String, _ projectPath: String) -> Void

    @State private var instruction = ""
    @State private var selectedProjectPath: String?
    @FocusState private var fieldFocused: Bool

    init(
        element: InspectedAXElement,
        projects: [Project],
        onSend: @escaping (_ instruction: String, _ projectPath: String) -> Void,
        onSave: @escaping (_ instruction: String, _ projectPath: String) -> Void
    ) {
        self.element = element
        self.projects = projects
        self.onSend = onSend
        self.onSave = onSave
        _selectedProjectPath = State(initialValue: Self.bestMatch(
            appName: element.app.name, in: projects
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            factRow(label: "ELEMENT", primary: elementFact)
            factRow(
                label: "IDENTIFIER",
                primary: element.identifier,
                mono: true,
                copyText: element.identifier
            )
            factRow(
                label: "APP",
                primary: appFact,
                copyText: element.app.bundlePath
            )
            projectRow
            promptField
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .onAppear {
            // One async hop — focusing during popover presentation is
            // silently dropped.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(element.summary)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let windowTitle = element.windowTitle, !windowTitle.isEmpty {
                Text("in “\(windowTitle)”")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var elementFact: String {
        var parts = [element.roleDescription ?? InspectedAXElement.deAX(element.role)]
        if let title = element.title, !title.isEmpty { parts.append("“\(title)”") }
        if !element.enabled { parts.append("(disabled)") }
        return parts.joined(separator: " ")
    }

    private var appFact: String {
        element.app.bundlePath.map { "\(element.app.name) · \($0)" } ?? element.app.name
    }

    private func factRow(
        label: String,
        primary: String?,
        mono: Bool = false,
        copyText: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
                .frame(width: 72, alignment: .leading)
            if let primary, !primary.isEmpty {
                Text(primary)
                    .font(.system(size: 12, design: mono ? .monospaced : .default))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let copyText, !copyText.isEmpty {
                    CopyIconButton(text: copyText, help: "Copy")
                }
            } else {
                Text("none")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var projectRow: some View {
        HStack(spacing: 8) {
            Text("PROJECT")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
                .frame(width: 72, alignment: .leading)
            Picker("", selection: $selectedProjectPath) {
                Text("None").tag(String?.none)
                ForEach(projects) { project in
                    Text(project.name).tag(String?.some(project.path))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var canPrompt: Bool {
        selectedProjectPath != nil
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptField: some View {
        HStack(spacing: 8) {
            TextField("Describe a change to this element…", text: $instruction)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit { sendNow() }
            Button("Send to Claude") { sendNow() }
                .font(.system(size: 12))
                .controlSize(.small)
                .disabled(!canPrompt)
            Button("Add to Tasks") { saveToList() }
                .font(.system(size: 12))
                .controlSize(.small)
                .disabled(!canPrompt)
        }
    }

    private func sendNow() {
        guard canPrompt, let path = selectedProjectPath else { return }
        onSend(instruction.trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    private func saveToList() {
        guard canPrompt, let path = selectedProjectPath else { return }
        onSave(instruction.trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    /// "Houston" (app) → the "houston" project: normalized (lowercased,
    /// separators stripped) exact match first, then prefix either way.
    private static func bestMatch(appName: String, in projects: [Project]) -> String? {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let app = normalize(appName)
        guard !app.isEmpty else { return nil }
        if let exact = projects.first(where: { normalize($0.name) == app }) {
            return exact.path
        }
        return projects.first { project in
            let name = normalize(project.name)
            return !name.isEmpty && (name.hasPrefix(app) || app.hasPrefix(name))
        }?.path
    }
}
