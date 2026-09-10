import SwiftUI

/// One saved-change row, shared by the web preview's annotations panel and
/// the main window's Saved Changes sheet. Actions arrive as closures so
/// each host wires its own delivery.
struct AnnotationRowView: View {
    let item: Annotation
    /// Project root for resolving a web capture's file for the detail line.
    let projectPath: String?
    /// Card styling for the tasks sheet. The web preview's list keeps the
    /// quiet hover-pill rows — it draws on `panelFill`, where cards vanish.
    var carded = false
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
        HStack(alignment: .center, spacing: 10) {
            checkbox
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if editing {
                        // Vertical axis so a long task wraps while editing
                        // instead of scrolling inside a one-line field.
                        TextField("", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1...8)
                            .focused($editFocused)
                            .onSubmit { commitEdit() }
                            .onExitCommand { editing = false }
                    } else {
                        ExpandableTaskText(text: item.comment, done: item.done)
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
                AnnotationIconButton(symbol: "trash", help: "Delete", action: onDelete)
            }
            .frame(height: 21)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
        .padding(.horizontal, carded ? 10 : 12)
        .padding(.vertical, carded ? 8 : 6)
        .background(
            RoundedRectangle(cornerRadius: carded ? 8 : 6)
                .fill(hovered ? Theme.rowHovered : (carded ? Theme.panelFill : .clear))
                .padding(.horizontal, carded ? 0 : 6)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// Always-visible toggle — done rows fill it, open rows are an empty
    /// ring. Replaces both the old bullet and the hover-only checkmark.
    private var checkbox: some View {
        Button(action: onToggleDone) {
            ZStack {
                if item.done {
                    Circle().fill(Theme.dotActive)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Theme.buttonActiveStroke, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(item.done ? "Reopen" : "Mark done")
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
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Task text clamped to 3 lines, with a "more"/"less" toggle that only
/// appears when the text is actually clipped — a long task stays readable
/// without every short row paying for the affordance.
private struct ExpandableTaskText: View {
    let text: String
    let done: Bool

    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .strikethrough(done)
                .lineLimit(expanded ? nil : 3)
                .background(expanded ? nil : truncationProbe)
            if truncated || expanded {
                // A Button so the click doesn't bubble into the row's
                // tap-to-edit gesture.
                Button(expanded ? "less" : "more") {
                    withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// A hidden unclamped copy at the same width, measured against the
    /// clamped render — taller means the visible text is truncated.
    private var truncationProbe: some View {
        GeometryReader { clamped in
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: clamped.size.width, alignment: .leading)
                .hidden()
                .background(
                    GeometryReader { full in
                        Color.clear
                            .onAppear {
                                truncated = full.size.height > clamped.size.height + 1
                            }
                            .onChange(of: full.size.height) { _, height in
                                truncated = height > clamped.size.height + 1
                            }
                    }
                )
        }
    }
}

/// The Saved Changes list rendered in the main window's right sheet —
/// element comments queued from the web preview,
/// sendable to this project's terminal one at a time or batched.
struct AnnotationsSheetPanel: View {
    @ObservedObject var store: AnnotationStore
    let projectPath: String

    @State private var newChange = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.items.isEmpty {
                        Text("Inspect an element in a web preview, then “Add to Tasks” — or type a task below.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 2)
                            .padding(.top, 4)
                    }
                    ForEach(store.open) { item in
                        row(item)
                    }
                    if !store.doneItems.isEmpty {
                        Text("DONE")
                            .font(.system(size: 9, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.heading)
                            .padding(.horizontal, 2)
                            .padding(.top, 10)
                        ForEach(store.doneItems) { item in
                            row(item).opacity(0.55)
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.switchTrackOn))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(newChangeEmpty)
            .opacity(newChangeEmpty ? 0.4 : 1)
            .help("Add to the change list")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panelFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.buttonStroke, lineWidth: 1))
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

    private func row(_ item: Annotation) -> some View {
        AnnotationRowView(
            item: item,
            projectPath: projectPath,
            carded: true,
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
/// page pushes on top of it — no matter whether the sheet was opened from
/// the footer (root) or a terminal header (nested). Back lives in the
/// sheet's title bar, not here.
struct TasksNavigator: View {
    /// nil = the All Tasks root.
    let projectPath: String?
    /// Tracked items needing attention — the Reminders row's badge.
    let trackedAttention: Int
    let onOpenProject: (String) -> Void
    let onOpenReminders: () -> Void

    var body: some View {
        if let projectPath {
            AnnotationsSheetPanel(
                store: AnnotationStores.store(for: projectPath),
                projectPath: projectPath
            )
        } else {
            AllTasksPanel(
                trackedAttention: trackedAttention,
                onOpenProject: onOpenProject,
                onOpenReminders: onOpenReminders
            )
        }
    }
}

/// Every project's tasks in one sheet — the sidebar footer's checklist and
/// the root of the tasks hierarchy. Project headers push into that
/// project's page; sending routes each task to its own project's terminal.
struct AllTasksPanel: View {
    let trackedAttention: Int
    let onOpenProject: (String) -> Void
    let onOpenReminders: () -> Void

    @State private var stores: [AnnotationStore] = []
    @State private var projects: [Project] = []
    @State private var newTask = ""
    @State private var targetProject: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    RemindersRow(attention: trackedAttention, action: onOpenReminders)
                    if stores.isEmpty {
                        Text("No tasks yet. Queue changes from a web preview, or type one below.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 2)
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
            chatInput
        }
        .onAppear {
            stores = AnnotationStores.allStores()
            reloadProjects()
        }
    }

    /// Same pill as a project's Tasks page, with a project picker sitting
    /// above it so the task lands in the right list.
    private var chatInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(projects) { project in
                    Button(project.name) { targetProject = project.path }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(targetProjectName ?? "Project")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(targetProject == nil ? Theme.textSecondary : Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowHovered))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Which project this task belongs to")
            HStack(spacing: 8) {
                TextField("Add a task…", text: $newTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { addTask() }
                Button(action: addTask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.switchTrackOn))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
                .help(targetProject == nil ? "Pick a project first" : "Add to the task list")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panelFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.buttonStroke, lineWidth: 1))
        }
        .padding(.top, 8)
    }

    private var targetProjectName: String? {
        targetProject.map { ($0 as NSString).lastPathComponent }
    }

    private var canAdd: Bool {
        targetProject != nil
            && !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addTask() {
        guard canAdd, let path = targetProject else { return }
        let trimmed = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AnnotationStores.store(for: path).add(comment: trimmed)
        newTask = ""
        // A first task for a project creates its store — re-list so the new
        // section appears without waiting for a reopen.
        stores = AnnotationStores.allStores()
    }

    /// Sidebar projects plus any project that already has a task file but
    /// lives outside the configured folders.
    private func reloadProjects() {
        var list = ProjectList.allProjects(settings: HoustonSettings.read())
        var seen = Set(list.map(\.path))
        for store in stores where seen.insert(store.projectPath).inserted {
            list.append(Project(
                id: store.projectPath,
                name: (store.projectPath as NSString).lastPathComponent,
                path: store.projectPath,
                modifiedMs: 0
            ))
        }
        projects = list.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// The All Tasks root's Reminders entry — a card row that pushes the
/// Tracked reminders page, carrying the attention dot and count so due
/// items stay visible without opening it.
private struct RemindersRow: View {
    let attention: Int
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Reminders")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                if attention > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.dotDegraded)
                            .frame(width: 5, height: 5)
                        Text("\(attention)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Theme.rowHovered : Theme.panelFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Tracked reminders")
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
                HStack(spacing: 6) {
                    Text((store.projectPath as NSString).lastPathComponent)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(headerHovered ? Theme.link : Theme.text)
                        .lineLimit(1)
                    if !store.open.isEmpty {
                        Text("\(store.open.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.panelFill))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(headerHovered ? Theme.link : Theme.heading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { headerHovered = $0 }
            .help("Open this project's tasks")
            ForEach(store.open) { item in
                row(item)
            }
            ForEach(store.doneItems) { item in
                row(item).opacity(0.55)
            }
        }
    }

    private func row(_ item: Annotation) -> some View {
        AnnotationRowView(
            item: item,
            projectPath: store.projectPath,
            carded: true,
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
