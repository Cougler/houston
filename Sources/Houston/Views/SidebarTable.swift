import AppKit
import SwiftUI

/// One row in the sidebar. Headers are non-selectable group rows; folders are
/// collapsible parents inside the Projects section — clickable (to toggle)
/// but never *selected*. Collapse state deliberately lives outside the entry:
/// inside it, toggling would change the element's hash and the diff would
/// rebuild the row (remove+insert) instead of updating it in place.
enum SidebarEntry: Identifiable, Hashable {
    case header(String)
    case folder(path: String, name: String)
    case row(id: SidebarSelection, title: String)
    /// A project's home row in the Projects library. Selecting it targets the
    /// same `.project` selection as an Active row, but it has its own row
    /// identity — so a running project stays put here (with a live dot) while
    /// also being listed under Active, instead of jumping sections.
    case library(path: String, title: String)
    /// A clickable affordance inside a section (e.g. "New Terminal" while no
    /// terminal is open) — like a folder, tappable but never *selected*.
    case action(key: String, title: String)

    var id: String {
        switch self {
        case let .header(title): "header:\(title)"
        case let .folder(path, _): "folder:\(path)"
        case let .action(key, _): "action:\(key)"
        case let .library(path, _): "library:\(path)"
        case let .row(id, _):
            switch id {
            case let .project(path): "project:\(path)"
            case let .shell(_, tab): "shell:\(tab)"
            case let .server(sid): "server:\(sid)"
            }
        }
    }

    var selection: SidebarSelection? {
        switch self {
        case let .row(id, _): return id
        case let .library(path, _): return .project(path)
        default: return nil
        }
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    /// Only real rows can hold the selection — headers and actions can't,
    /// which also keeps arrow-key navigation from parking on them. Server
    /// rows opted out too: clicking one pops a detail popover instead of
    /// changing what the detail pane shows.
    var isSelectable: Bool {
        switch self {
        case let .row(id, _):
            if case .server = id { return false }
            return true
        case .library: return true
        default: return false
        }
    }
}

/// An `NSTableView`-backed sidebar with SwiftUI row content.
///
/// SwiftUI's `List` is fine until you need control of the row *box*: on macOS
/// it layers self-sizing on top of `NSTableView` in a way Apple doesn't
/// support, so row height can't be driven from content, and it draws selection
/// but not hover. Wrapping `NSTableView` directly keeps everything the platform
/// gives for free — arrow-key navigation, type-ahead, VoiceOver rows,
/// scroll-to-selection, native source-list selection styling — while handing us
/// exact row heights and a real hover signal.
///
/// Rows are still ordinary SwiftUI views; they're hosted per row.
struct SidebarTable<Row: View>: NSViewRepresentable {
    let entries: [SidebarEntry]
    @Binding var selection: SidebarSelection?
    /// Height for a given entry, in points. This is the whole reason for the
    /// wrapper — `List` won't honour it.
    let heightForEntry: (SidebarEntry) -> CGFloat
    /// Row content. `isHovered` is supplied by the table's tracking area.
    @ViewBuilder let content: (SidebarEntry, Bool) -> Row
    /// A cheap signature of everything `content` renders for this row.
    ///
    /// The stores republish every ~2s, so `updateNSView` runs constantly even
    /// when nothing visible changed. Re-hosting each row's SwiftUI view on
    /// every tick is what made the sidebar flicker; comparing keys means a row
    /// is only rebuilt when its own content actually differs.
    let contentKey: (SidebarEntry, Bool) -> String
    /// Right-click menu for a row, if any.
    var menuForEntry: ((SidebarEntry) -> NSMenu?)? = nil
    /// Fired on every left click that lands on a selectable row — including
    /// one that's already selected, which `selection` alone can't report.
    /// Used to hand keyboard focus back to the row's terminal.
    var onRowClick: ((SidebarEntry) -> Void)? = nil
    /// Fired when a left click lands below/between the rows — the sidebar's
    /// dead space. Used to dismiss the floating right sheet.
    var onEmptyClick: (() -> Void)? = nil
    /// Fired on a double click on a selectable row — inline rename.
    var onRowDoubleClick: ((SidebarEntry) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HoverTableView()
        // `.fullWidth`, not `.sourceList`: the source-list style stacks its
        // own ~16pt horizontal cell insets on top of the row padding, pushing
        // every row well right of the design's metrics. Rows draw all their
        // own chrome anyway.
        table.style = .fullWidth
        table.headerView = nil
        table.backgroundColor = .clear
        // We draw selection ourselves in `RowChrome`. Leaving the source-list
        // style to also draw it stacked a slightly wider native pill behind
        // ours — the same mismatched-geometry problem as the old hover layer.
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Pinned group rows draw their own background + hairline while
        // floating — the design has no rules between sections.
        table.floatsGroupRows = false
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.onHoverChange = { [weak coordinator = context.coordinator] row in
            coordinator?.setHovered(row)
        }
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.menuForRow(row)
        }
        table.onRowClick = { [weak coordinator = context.coordinator] row in
            coordinator?.rowClicked(row)
        }
        table.onRowDoubleClick = { [weak coordinator = context.coordinator] row in
            coordinator?.rowDoubleClicked(row)
        }
        table.onEmptyClick = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEmptyClick?()
        }
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        // No scroller at all — trackpad scrolling still works, and the
        // design's sidebar has no scroll bar. (An overlay scroller still
        // renders persistently when "Show scroll bars: Always" is on.)
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(entries)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SidebarTable
        var entries: [SidebarEntry] = []
        weak var table: NSTableView?
        private var hoveredRow: Int?
        /// Last rendered content key per entry id — see `contentKey`.
        private var renderedKeys: [String: String] = [:]
        /// Set while pushing a selection *into* the table, so the resulting
        /// delegate callback doesn't echo back and fight the binding.
        private var isSyncing = false

        init(_ parent: SidebarTable) {
            self.parent = parent
            self.entries = parent.entries
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard entries.indices.contains(row) else { return 24 }
            return parent.heightForEntry(entries[row])
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            entries.indices.contains(row) && entries[row].isHeader
        }

        func tableView(
            _ tableView: NSTableView,
            selectionIndexesForProposedSelection proposed: IndexSet
        ) -> IndexSet {
            proposed.filter { entries.indices.contains($0) && entries[$0].isSelectable }
                .reduce(into: IndexSet()) { $0.insert($1) }
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            let id = NSUserInterfaceItemIdentifier("row")
            let host: HostingRowView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? HostingRowView {
                host = reused
            } else {
                host = HostingRowView()
                host.identifier = id
            }
            // A reused view still holds another row's content, so always set.
            render(host, entry: entry, row: row, force: true)
            return host
        }

        /// Re-hosts a row's SwiftUI content only when its key changed.
        private func render(
            _ host: HostingRowView,
            entry: SidebarEntry,
            row: Int,
            force: Bool
        ) {
            let key = parent.contentKey(entry, hoveredRow == row)
            if !force, renderedKeys[entry.id] == key { return }
            renderedKeys[entry.id] = key
            host.set(parent.content(entry, hoveredRow == row))
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            // A plain row view keeps the source-list selection pill but drops
            // the default alternating/backing fills.
            let id = NSUserInterfaceItemIdentifier("rowbg")
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView {
                return reused
            }
            let view = NSTableRowView()
            view.identifier = id
            return view
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            let row = table.selectedRow
            guard entries.indices.contains(row) else {
                parent.selection = nil
                return
            }
            parent.selection = entries[row].selection
        }

        /// Reconciles the table with a new entry list.
        ///
        /// `reloadData()` was the flicker: it discards and rebuilds *every* row
        /// view, and the list changes on every 2s poll and on every click (a
        /// project moves from Projects to Shells the moment its pane opens).
        /// Instead, structural changes are applied as row moves, inserts and
        /// removes, and rows that persist just get their hosted SwiftUI content
        /// refreshed in place — SwiftUI diffs that internally, so nothing
        /// visibly redraws.
        ///
        /// Moves matter as much as the diff itself: a project entering Shells
        /// keeps its entry id, so without `inferringMoves()` it diffs as a
        /// remove+insert pair and its row view — hosted SwiftUI content and
        /// all — is torn down and rebuilt. `moveRow` keeps the same row view
        /// alive across the jump, so nothing flashes.
        func apply(_ newEntries: [SidebarEntry]) {
            guard let table else { return }

            if newEntries != entries {
                let diff = newEntries.difference(from: entries).inferringMoves()
                // Mirror of the table's row order mid-batch, used to locate a
                // move's source row at the moment the move is issued —
                // NSTableView applies batched calls serially, not all-at-once.
                var order = entries.map(\.id)
                entries = newEntries

                // Structural calls can bounce selection through the delegate
                // (removing the selected row fires `selectionDidChange`),
                // which would write into the SwiftUI binding mid-update and
                // blank the detail pane for a frame. Gate the echo; selection
                // is reconciled in `syncSelectionToTable` below.
                isSyncing = true
                table.beginUpdates()
                // Pure removals high-to-low (offsets index the old array),
                // then insertions/moves low-to-high (offsets index the new
                // array) — the order under which serial application matches
                // `CollectionDifference.applying`.
                for case let .remove(offset, _, associatedWith) in diff.removals.reversed()
                where associatedWith == nil {
                    table.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                    order.remove(at: offset)
                }
                for case let .insert(offset, element, associatedWith) in diff.insertions {
                    if associatedWith != nil, let from = order.firstIndex(of: element.id) {
                        table.moveRow(at: from, to: offset)
                        order.remove(at: from)
                    } else {
                        table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                    }
                    order.insert(element.id, at: offset)
                }
                // A moved row keeps its view but may change height (a project
                // row is shorter than a shell row) — heights aren't re-queried
                // without an explicit note.
                table.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: 0..<newEntries.count)
                )
                table.endUpdates()
                isSyncing = false

                // Rows shifted: drop keys for entries that left, and re-derive
                // which row is under the pointer — hover is tracked by index,
                // and the old index now names whatever row slid into it.
                let ids = Set(newEntries.map(\.id))
                renderedKeys = renderedKeys.filter { ids.contains($0.key) }
                refreshHoverFromPointer()
            }

            refreshVisibleRows()
            syncSelectionToTable()
        }

        /// Recomputes the hovered row from the pointer's actual location.
        private func refreshHoverFromPointer() {
            guard let table, let window = table.window else { return }
            let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let row = table.row(at: point)
            setHovered(row >= 0 ? row : nil)
        }

        /// Push current state into the rows already on screen. Row *identity*
        /// is unchanged here — only its contents (context %, agent badge,
        /// selection tint), so replacing the hosted root view is enough.
        private func refreshVisibleRows() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.lowerBound..<visible.upperBound {
                guard entries.indices.contains(row) else { continue }
                guard let host = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? HostingRowView else { continue }
                render(host, entry: entries[row], row: row, force: false)
            }
        }

        func syncSelectionToTable() {
            guard let table else { return }
            let target = parent.selection.flatMap { sel in
                entries.firstIndex { $0.selection == sel }
            }
            let current = table.selectedRow >= 0 ? table.selectedRow : nil
            guard target != current else { return }
            isSyncing = true
            if let target {
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                table.scrollRowToVisible(target)
            } else {
                table.deselectAll(nil)
            }
            isSyncing = false
        }

        // MARK: Hover

        func setHovered(_ row: Int?) {
            guard hoveredRow != row else { return }
            let previous = hoveredRow
            hoveredRow = row
            // Rebuild only the two rows whose hover state actually changed.
            for candidate in [previous, row].compactMap({ $0 }) {
                guard let table, entries.indices.contains(candidate) else { continue }
                if let host = table.view(atColumn: 0, row: candidate, makeIfNecessary: false)
                    as? HostingRowView {
                    render(host, entry: entries[candidate], row: candidate, force: false)
                }
            }
        }

        // MARK: Context menu

        func menuForRow(_ row: Int) -> NSMenu? {
            guard entries.indices.contains(row) else { return nil }
            return parent.menuForEntry?(entries[row])
        }

        // MARK: Clicks

        func rowClicked(_ row: Int) {
            guard entries.indices.contains(row) else { return }
            let entry = entries[row]
            guard entry.isSelectable else { return }
            parent.onRowClick?(entry)
        }

        func rowDoubleClicked(_ row: Int) {
            guard entries.indices.contains(row) else { return }
            let entry = entries[row]
            guard entry.isSelectable else { return }
            parent.onRowDoubleClick?(entry)
        }
    }
}

/// `NSTableView` has no hover concept, so we add one: a tracking area reports
/// the row under the pointer, which the SwiftUI row content renders.
private final class HoverTableView: NSTableView {
    var onHoverChange: ((Int?) -> Void)?
    /// Supplied by `makeNSView` so the menu lookup never crosses an isolation
    /// boundary (a `SidebarMenuProviding` conformance did, and `NSMenu` isn't
    /// `Sendable`).
    var menuProvider: ((Int) -> NSMenu?)?
    /// Every left click on a row, selected or not — `selectionDidChange`
    /// stays silent when the clicked row is already selected.
    var onRowClick: ((Int) -> Void)?
    /// A click that hits no row at all — the space below the last row.
    var onEmptyClick: (() -> Void)?
    /// The second click of a double click on a row.
    var onRowDoubleClick: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        // super runs the selection tracking loop first; the click callback
        // fires after, so it sees the settled selection.
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 { onRowClick?(row) } else { onEmptyClick?() }
        if event.clickCount == 2, row >= 0 { onRowDoubleClick?(row) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        onHoverChange?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(nil)
    }

    /// Right-click should target the row under the cursor without stealing
    /// selection, matching Finder/Xcode behaviour.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return super.menu(for: event) }
        return menuProvider?(row) ?? super.menu(for: event)
    }
}

/// A table cell that hosts arbitrary SwiftUI content.
private final class HostingRowView: NSTableCellView {
    private var hosting: NSHostingView<AnyView>?

    func set(_ view: some View) {
        let erased = AnyView(view)
        if let hosting {
            hosting.rootView = erased
            return
        }
        let host = NSHostingView(rootView: erased)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosting = host
    }
}
