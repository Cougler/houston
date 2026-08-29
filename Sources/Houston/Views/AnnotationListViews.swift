import SwiftUI

/// One saved-change row, shared by the web preview's annotations panel and
/// the main window's Saved Changes sheet. Actions arrive as closures so
/// each host wires its own delivery.
struct AnnotationRowView: View {
    let item: Annotation
    /// Position in the open list — matches the preview's page pin. nil for
    /// done rows.
    let pin: Int?
    /// Project root for resolving a web capture's file for the detail line.
    let projectPath: String?
    let onSend: () -> Void
    let onToggleDone: () -> Void
    let onDelete: () -> Void
    /// Commit an edited comment. Clicking the text starts editing.
    let onEdit: (String) -> Void

    @State private var hovered = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        // Center-aligned with the action strip ALWAYS mounted (opacity
        // toggles): hovering must not change the row's height, or the text
        // sits high in the hover pill. The strip's 21pt (odd) height keeps
        // odd-height text centering on whole pixels.
        HStack(alignment: .center, spacing: 8) {
            // A quiet bullet for open items — the number only lives on the
            // web preview's page pins.
            if pin != nil {
                Circle()
                    .fill(Theme.buttonActiveStroke)
                    .frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if editing {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .focused($editFocused)
                            .onSubmit { commitEdit() }
                            .onExitCommand { editing = false }
                    } else {
                        Text(item.comment)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .strikethrough(item.done)
                            .lineLimit(3)
                    }
                    if item.sent && !item.done && !editing {
                        Text("SENT")
                            .font(.system(size: 8, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.textPositive)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // Click the text to edit it in place; Enter commits, Escape
            // (or focus leaving) backs out.
            .contentShape(Rectangle())
            .onTapGesture { beginEdit() }
            .onChange(of: editFocused) { _, focused in
                if !focused && editing { commitEdit() }
            }
            .help(editing ? "" : "Click to edit")
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if !item.done {
                    AnnotationIconButton(symbol: "paperplane", help: "Send to Claude now", action: onSend)
                }
                AnnotationIconButton(
                    symbol: item.done ? "arrow.uturn.backward" : "checkmark.circle",
                    help: item.done ? "Reopen" : "Mark done",
                    action: onToggleDone
                )
                AnnotationIconButton(symbol: "trash", help: "Delete", action: onDelete)
            }
            .frame(height: 21)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Theme.rowHovered : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func beginEdit() {
        guard !editing else { return }
        draft = item.comment
        editing = true
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEdit() {
        guard editing else { return }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != item.comment { onEdit(trimmed) }
    }

    private var detail: String {
        var parts = [item.summaryText]
        if let element = item.element {
            if let projectPath,
               let resolved = ElementSourceResolver.resolve(
                   element.structure?.file, projectRoot: projectPath
               ) {
                parts.append(resolved.relativePath)
            }
        } else if let axElement = item.axElement {
            parts.append(axElement.app.name)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The Saved Changes list rendered in the main window's right sheet —
/// element comments queued from the web preview and the App Inspector,
/// sendable to this project's terminal one at a time or batched.
struct AnnotationsSheetPanel: View {
    @ObservedObject var store: AnnotationStore
    let projectPath: String

    @State private var newChange = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.items.isEmpty {
                        Text("Inspect an element in a web preview or via the menubar's Inspect an App, then “Add to Tasks” — or type a task below.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                    ForEach(Array(store.open.enumerated()), id: \.element.id) { index, item in
                        row(item, pin: index + 1)
                    }
                    if !store.doneItems.isEmpty {
                        Text("DONE")
                            .font(.system(size: 9, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.heading)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(store.doneItems) { item in
                            row(item, pin: nil).opacity(0.55)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            if !unsentOpen.isEmpty {
                Rectangle()
                    .fill(Theme.borderFooter)
                    .frame(height: 1)
                Button("Send all open (\(unsentOpen.count))") { sendAll() }
                    .font(.system(size: 12))
                    .controlSize(.small)
                    .padding(.vertical, 10)
            }
            chatInput
        }
    }

    /// Manual capture, chat-style: a pill input pinned to the bottom with
    /// a round send button living inside it. Enter submits too.
    private var chatInput: some View {
        HStack(spacing: 8) {
            TextField("Add a task…", text: $newChange)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { addManual() }
            Button(action: addManual) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.switchTrackOn))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(newChangeEmpty)
            .opacity(newChangeEmpty ? 0.4 : 1)
            .help("Add to the change list")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(Capsule().fill(Theme.panelFill))
        .overlay(Capsule().stroke(Theme.buttonStroke, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var newChangeEmpty: Bool {
        newChange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unsentOpen: [Annotation] {
        store.open.filter { !$0.sent }
    }

    private func addManual() {
        let trimmed = newChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(comment: trimmed)
        newChange = ""
    }

    private func row(_ item: Annotation, pin: Int?) -> some View {
        AnnotationRowView(
            item: item,
            pin: pin,
            projectPath: projectPath,
            onSend: {
                PromptDelivery.send(
                    AnnotationPrompts.compose(item, projectRoot: projectPath),
                    toProject: projectPath
                )
                store.markSent(item.id)
            },
            onToggleDone: {
                item.done ? store.markUndone(item.id) : store.markDone(item.id)
            },
            onDelete: { store.remove(item.id) },
            onEdit: { store.updateComment(item.id, comment: $0) }
        )
    }

    private func sendAll() {
        let pending = unsentOpen
        guard !pending.isEmpty else { return }
        PromptDelivery.send(
            AnnotationPrompts.composeBatch(pending, projectRoot: projectPath),
            toProject: projectPath
        )
        for item in pending { store.markSent(item.id) }
    }
}

/// The tasks sheet's navigation shell: All Tasks is the root; a project's
/// page pushes on top of it, and Back pops up — no matter whether the
/// sheet was opened from the footer (root) or a terminal header (nested).
struct TasksNavigator: View {
    /// nil = the All Tasks root.
    let projectPath: String?
    let onOpenProject: (String) -> Void
    let onBack: () -> Void

    var body: some View {
        if let projectPath {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ControlIconButton(
                        systemName: "chevron.left",
                        help: "Back to All Tasks",
                        bare: true,
                        circleSize: 24,
                        action: onBack
                    )
                    Text((projectPath as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                AnnotationsSheetPanel(
                    store: AnnotationStores.store(for: projectPath),
                    projectPath: projectPath
                )
                .frame(maxHeight: .infinity)
            }
        } else {
            AllTasksPanel(onOpenProject: onOpenProject)
        }
    }
}

/// Every project's tasks in one sheet — the sidebar footer's checklist and
/// the root of the tasks hierarchy. Project headers push into that
/// project's page; sending routes each task to its own project's terminal.
struct AllTasksPanel: View {
    let onOpenProject: (String) -> Void

    @State private var stores: [AnnotationStore] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if stores.isEmpty {
                    Text("No tasks yet. Queue changes from a web preview, the App Inspector, or a project's Tasks page.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                ForEach(stores, id: \.projectPath) { store in
                    ProjectTasksSection(store: store) {
                        onOpenProject(store.projectPath)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .onAppear { stores = AnnotationStores.allStores() }
    }
}

/// One project's slice of the All Tasks sheet — its own view so each
/// store's changes re-render just its section.
private struct ProjectTasksSection: View {
    @ObservedObject var store: AnnotationStore
    let onOpen: () -> Void

    @State private var headerHovered = false

    var body: some View {
        if !store.items.isEmpty {
            Button(action: onOpen) {
                HStack(spacing: 4) {
                    Text((store.projectPath as NSString).lastPathComponent.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.5)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(headerHovered ? Theme.text : Theme.heading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { headerHovered = $0 }
            .help("Open this project's tasks")
            ForEach(Array(store.open.enumerated()), id: \.element.id) { index, item in
                row(item, pin: index + 1)
            }
            ForEach(store.doneItems) { item in
                row(item, pin: nil).opacity(0.55)
            }
        }
    }

    private func row(_ item: Annotation, pin: Int?) -> some View {
        AnnotationRowView(
            item: item,
            pin: pin,
            projectPath: store.projectPath,
            onSend: {
                PromptDelivery.send(
                    AnnotationPrompts.compose(item, projectRoot: store.projectPath),
                    toProject: store.projectPath
                )
                store.markSent(item.id)
            },
            onToggleDone: {
                item.done ? store.markUndone(item.id) : store.markDone(item.id)
            },
            onDelete: { store.remove(item.id) },
            onEdit: { store.updateComment(item.id, comment: $0) }
        )
    }
}

private struct AnnotationIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
