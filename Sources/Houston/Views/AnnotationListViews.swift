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
            // Carded (tasks sheet): the checkbox centers in the same
            // fixed 26pt leading slot as the sheet lists' icons.
            checkbox
                .frame(width: carded ? 26 : 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if editing {
                        // Vertical axis so a long task wraps while editing
                        // instead of scrolling inside a one-line field.
                        TextField("", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(Theme.Fonts.body)
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
                            .font(Theme.Fonts.label)
                            .kerning(0.5)
                            .foregroundStyle(Theme.textPositive)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Fonts.secondary)
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
        // Carded rows share the sheet lists' anatomy: 48pt floor (a long
        // task still grows), hover pill, full-width hairline underneath
        // that hides beneath the pill.
        .frame(minHeight: carded ? 48 : 0)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(hovered ? Theme.rowHovered : .clear)
                .padding(.horizontal, carded ? 0 : 6)
        )
        .overlay(alignment: .bottom) {
            if carded {
                Rectangle()
                    .fill(Theme.borderSidebar)
                    .frame(height: 1)
                    .opacity(hovered ? 0 : 1)
            }
        }
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
                .font(Theme.Fonts.body)
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
                .font(Theme.Fonts.body)
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
                // Flush rows (no spacing) so the hairlines read as one
                // linear list, like the SERVERS page.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.items.isEmpty {
                        Text("Inspect an element in a web preview, then “Add to Tasks” — or type a task below.")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }
                    ForEach(store.open) { item in
                        row(item)
                    }
                    if !store.doneItems.isEmpty {
                        sheetSectionLabel("DONE")
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
                    .font(Theme.Fonts.body)
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
                .font(Theme.Fonts.body)
                .onSubmit { addManual() }
            Button(action: addManual) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.switchTrackOn))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
            }
            .buttonStyle(.plain)
            .disabled(newChangeEmpty)
            .opacity(newChangeEmpty ? 0.4 : 1)
            .help("Add to the change list")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(Theme.attachedWellFill))
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
                // The same linear list as the SERVERS page (2026-09-14):
                // Reminders on top, then a row per project pushing into
                // its task page — the tasks themselves live there.
                VStack(alignment: .leading, spacing: 0) {
                    SheetListRow(
                        title: "Reminders",
                        subtitle: trackedAttention > 0
                            ? "\(trackedAttention) need attention"
                            : "Tracked obligations",
                        dot: trackedAttention > 0,
                        onTap: onOpenReminders,
                        icon: {
                            Image(systemName: "bell")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    )
                    sheetSectionLabel("PROJECTS")
                    if stores.isEmpty {
                        Text("No tasks yet. Queue changes from a web preview, or type one below.")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }
                    ForEach(stores, id: \.projectPath) { store in
                        ProjectTaskRow(store: store) {
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
                        .font(Theme.Fonts.secondaryMedium)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(targetProject == nil ? Theme.textSecondary : Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.rowHovered))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Which project this task belongs to")
            HStack(spacing: 8) {
                TextField("Add a task…", text: $newTask)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .onSubmit { addTask() }
                Button(action: addTask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.switchTrackOn))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
                .help(targetProject == nil ? "Pick a project first" : "Add to the task list")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(Theme.attachedWellFill))
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

/// One project's row in the All Tasks root — its own view so each
/// store's count changes re-render just its row. The tasks themselves
/// live in the project's pushed page.
private struct ProjectTaskRow: View {
    @ObservedObject var store: AnnotationStore
    let onOpen: () -> Void

    var body: some View {
        if !store.items.isEmpty {
            SheetListRow(
                title: (store.projectPath as NSString).lastPathComponent,
                subtitle: subtitle,
                onTap: onOpen,
                icon: {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            )
            .help("Open this project's tasks")
        }
    }

    private var subtitle: String {
        switch store.open.count {
        case 0: "All done"
        case 1: "1 open task"
        case let n: "\(n) open tasks"
        }
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
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
