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
    /// The composed task prompt, set by the tasks sheet: the row's action
    /// becomes COPY (paste it into any chat — Claude, Codex, Gemini,
    /// Grok) instead of the web preview's send-to-session paperplane.
    var copyText: String? = nil
    /// Non-nil swaps the trash button for a hover ⋯ menu (the tasks
    /// menu): assign the task to one of these projects, or delete.
    var moveChoices: [Project]? = nil
    var onMoveTo: ((String) -> Void)? = nil
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
                    if let copyText {
                        CopyIconButton(
                            text: copyText,
                            help: "Copy task — paste it into any chat"
                        )
                    } else {
                        AnnotationIconButton(icon: "send", help: "Send to Claude now", action: onSend)
                    }
                }
                if let moveChoices, let onMoveTo {
                    Menu {
                        Menu("Add to Project") {
                            ForEach(moveChoices) { project in
                                Button(project.name) { onMoveTo(project.path) }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        LucideIcon("ellipsis", size: 12)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 21, height: 21)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                } else {
                    AnnotationIconButton(icon: "trash-2", help: "Delete", action: onDelete)
                }
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
                // Faded like the sheet lists' rows — the full-strength
                // hairline read as a heavy rule between tasks.
                Rectangle()
                    .fill(Theme.borderSidebar.opacity(0.45))
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
                    LucideIcon("check", size: 10)
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Theme.heading, lineWidth: 1.5)
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
                LucideIcon("arrow-up", size: 14)
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
            // Copy, not send-to-Claude: the prompt pastes into ANY chat
            // (Claude, Codex, Gemini, Grok) or terminal.
            copyText: AnnotationPrompts.compose(item, projectRoot: projectPath),
            onSend: {},
            onToggleDone: {
                item.done ? store.markUndone(item.id) : store.markDone(item.id)
            },
            onDelete: { store.remove(item.id) },
            onEdit: { store.updateComment(item.id, comment: $0) }
        )
    }

}

/// The titlebar tasks menu (2026-09-23): OPEN tasks grouped by project
/// (with a "No project" group — the home-directory store, the same
/// stand-in chats use), an Add Project affordance, and a task input
/// pinned to the bottom. Completed tasks collapse behind a chevron row
/// and Reminders behind the bell at the top right — each its own pushed
/// page with a back arrow. The right sheet keeps the full navigator.
struct TasksMenuList: View {
    @ObservedObject var tracked: TrackedStore
    /// The card's height (~80% of the window) — fixed, not a ceiling:
    /// the list area fills it and the input stays pinned at the bottom,
    /// so the panel reads tall even with a short list.
    var maxHeight: CGFloat = 440

    private enum Page { case root, completed, reminders }
    @State private var page: Page = .root
    @State private var groupPaths: [String] = []
    /// Every project, for the rows' Add-to-Project menus.
    @State private var projects: [Project] = []
    @State private var newTask = ""

    private let home = NSHomeDirectory()

    var body: some View {
        Group {
            switch page {
            case .root: rootPage
            case .completed: completedPage
            case .reminders: remindersPage
            }
        }
        .frame(height: maxHeight, alignment: .top)
        .onAppear(perform: reload)
    }

    // MARK: Root — the task list

    private var rootPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                caps("TASKS")
                Spacer(minLength: 0)
                // Completed moved behind ⋯ (2026-09-23) — no row in the
                // list itself.
                Menu {
                    Button("Completed") {
                        withAnimation(Theme.quick) { page = .completed }
                    }
                } label: {
                    LucideIcon("ellipsis", size: 14)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                ControlIconButton(
                    icon: "bell", help: "Reminders", bare: true,
                    action: { withAnimation(Theme.quick) { page = .reminders } }
                )
                .overlay(alignment: .topTrailing) {
                    if tracked.attentionCount > 0 {
                        Circle()
                            .fill(Theme.dotDegraded)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groupPaths.isEmpty {
                        Text("No tasks yet — type one below.")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                    ForEach(groupPaths, id: \.self) { path in
                        TasksMenuGroup(
                            store: AnnotationStores.store(for: path),
                            title: groupTitle(path), done: false,
                            moveChoices: projects, onChanged: reload
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                .thinScrollbar()
            }
            // Fills whatever the card's fixed height leaves after the
            // header and the input band.
            .frame(maxHeight: .infinity)
            // shadcn separator grammar: a full-bleed hairline, then the
            // input on its own uniformly padded band.
            Rectangle()
                .fill(Theme.borderSidebar.opacity(0.6))
                .frame(height: 1)
            taskInput
                .padding(8)
        }
    }

    /// The bottom input: one plain field — a new task lands in No
    /// project; the row's ⋯ menu assigns it from there.
    private var taskInput: some View {
        HStack(spacing: 8) {
            TextField("Add a task…", text: $newTask)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .onSubmit(addTask)
            Button(action: addTask) {
                LucideIcon("arrow-up", size: 14)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSurface)
                            .fill(Theme.switchTrackOn)
                    )
                    .contentShape(
                        RoundedRectangle(cornerRadius: Theme.radiusSurface))
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .opacity(canAdd ? 1 : 0.4)
            .help("Add to the task list")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .fill(Theme.attachedWellFill)
        )
    }

    // MARK: Pushed pages

    private var completedPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("COMPLETED")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Its own listing, not `groupPaths` — a project whose
                    // tasks are ALL done has no root group but belongs
                    // here.
                    ForEach(completedPaths, id: \.self) { path in
                        TasksMenuGroup(
                            store: AnnotationStores.store(for: path),
                            title: groupTitle(path), done: true,
                            moveChoices: projects, onChanged: reload
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
                .thinScrollbar()
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 6)
    }

    private var completedPaths: [String] {
        var paths = AnnotationStores.allStores()
            .filter { !$0.doneItems.isEmpty }
            .map(\.projectPath)
        if let at = paths.firstIndex(of: home) {
            paths.append(paths.remove(at: at))
        }
        return paths
    }

    private var remindersPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("REMINDERS")
            TrackedPanel(store: tracked, compact: true)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 8)
    }

    /// Back arrow + caps title, both pushed pages.
    private func pageHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            ControlIconButton(
                icon: "arrow-left", help: "Back", bare: true,
                action: { withAnimation(Theme.quick) { page = .root } }
            )
            caps(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func caps(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
    }

    // MARK: Data

    private func groupTitle(_ path: String) -> String {
        path == home
            ? "NO PROJECT"
            : (path as NSString).lastPathComponent.uppercased()
    }

    private var canAdd: Bool {
        !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addTask() {
        let trimmed = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AnnotationStores.store(for: home).add(comment: trimmed)
        newTask = ""
        reload()
    }

    /// Only projects with OPEN tasks make the root list (a task file
    /// alone, or done-only, doesn't earn a header — those live on the
    /// Completed page). No-project last when it qualifies.
    private func reload() {
        var paths = AnnotationStores.allStores()
            .filter { !$0.open.isEmpty }
            .map(\.projectPath)
        if let at = paths.firstIndex(of: home) {
            paths.append(paths.remove(at: at))
        }
        groupPaths = paths
        projects = ProjectList.allProjects(settings: HoustonSettings.read())
    }
}

/// One project's group in the tasks menu: caps header + its rows —
/// open tasks on the root page, done tasks (dimmed) on Completed. Each
/// row's ⋯ menu can re-home the task to any other project.
private struct TasksMenuGroup: View {
    @ObservedObject var store: AnnotationStore
    let title: String
    /// false = open tasks (root page), true = done tasks (Completed).
    let done: Bool
    /// Every project, for the ⋯ menu (the row's own is filtered out).
    let moveChoices: [Project]
    /// A move/add/delete changed which groups exist — the list re-derives.
    let onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetSectionLabel(title)
            ForEach(done ? store.doneItems : store.open) { item in
                row(item).opacity(done ? 0.55 : 1)
            }
        }
    }

    private func row(_ item: Annotation) -> some View {
        AnnotationRowView(
            item: item,
            projectPath: store.projectPath,
            carded: true,
            copyText: AnnotationPrompts.compose(
                item, projectRoot: store.projectPath),
            moveChoices: moveChoices.filter { $0.path != store.projectPath },
            onMoveTo: { path in
                store.move(item.id, to: AnnotationStores.store(for: path))
                onChanged()
            },
            onSend: {},
            onToggleDone: {
                item.done ? store.markUndone(item.id) : store.markDone(item.id)
                onChanged()
            },
            onDelete: {
                store.remove(item.id)
                onChanged()
            },
            onEdit: { store.updateComment(item.id, comment: $0) }
        )
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
                            LucideIcon("bell", size: 16)
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
                    LucideIcon("chevrons-up-down", size: 10)
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
                    LucideIcon("arrow-up", size: 14)
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
                    LucideIcon("list-checks", size: 16)
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
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: 12)
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
