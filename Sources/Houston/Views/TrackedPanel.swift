import SwiftUI

/// The Tracked sheet: flat on the sheet's background with items as cards —
/// needs-attention first, then upcoming, then done history — plus manual
/// capture ("+ Track something") for items that don't come in through the
/// /track skill. Sections keep the sidebar's quiet caps labels; each card
/// carries title, dates, and notes in one clean hierarchy, with the actions
/// (done / postpone / untrack) replacing the countdown pill on hover.
struct TrackedPanel: View {
    @ObservedObject var store: TrackedStore

    enum SortKey: String, CaseIterable {
        case due, title, project
    }

    @State private var sort: SortKey = .due
    /// nil shows every project.
    @State private var filterProject: String?
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newDue =
        Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var newLeadDays = 30
    @State private var newProject = ""
    @State private var newNotes = ""

    /// Measured height of the scrolling list, so the scroll view hugs its
    /// content — that's what lets "Track something" trail the list until the
    /// list fills the sheet, at which point the frame cap kicks in and the
    /// button pins to the bottom.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let attention = arranged(store.active.filter(store.needsAttention))
        let upcoming = arranged(store.active.filter { !store.needsAttention($0) })
        let done = arranged(store.doneItems)
        return VStack(alignment: .leading, spacing: 8) {
            if !store.items.isEmpty {
                controls
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if store.items.isEmpty && !adding {
                        emptyState
                    }
                    if !attention.isEmpty {
                        sectionLabel("NEEDS ATTENTION")
                        ForEach(attention) { item in
                            card(item, attention: true)
                        }
                    }
                    if !upcoming.isEmpty {
                        sectionLabel("UPCOMING")
                        ForEach(upcoming) { item in
                            card(item, attention: false)
                        }
                    }
                    if !done.isEmpty {
                        sectionLabel("DONE")
                        ForEach(done) { item in
                            TrackedDoneCard(
                                item: item,
                                onRestore: { store.markUndone(item.id) },
                                onRemove: { store.remove(item.id) }
                            )
                        }
                    }
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ListHeightKey.self, value: g.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(ListHeightKey.self) { height in
                listHeight = height
            }
            .frame(maxHeight: listHeight > 0 ? listHeight : nil)
            if adding {
                addForm
            } else {
                addButton
            }
            skillHint
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Quiet pointer to the skill entry path — the chip makes /track read as
    /// a command, the line stays out of the way under the add button.
    private var skillHint: some View {
        HStack(spacing: 5) {
            Text("/track")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Theme.buttonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.buttonStroke, lineWidth: 1)
                )
            Text("say \u{201C}track \u{2026}\u{201D} in any Claude session to add one from there")
                .font(.system(size: 10))
                .foregroundStyle(Theme.heading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: - Sort & filter

    /// Distinct projects across every item, for the filter menu.
    private var projects: [String] {
        Array(Set(store.items.compactMap(\.project))).sorted()
    }

    private func arranged(_ items: [TrackedItem]) -> [TrackedItem] {
        var out = items
        if let filterProject {
            out = out.filter { $0.project == filterProject }
        }
        switch sort {
        case .due:
            break // the store's lists are already due-sorted
        case .title:
            out.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        case .project:
            // Projectless items sink to the bottom.
            out.sort { ($0.project ?? "\u{FFFF}") < ($1.project ?? "\u{FFFF}") }
        }
        return out
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Sort", selection: $sort) {
                    Text("Due date").tag(SortKey.due)
                    Text("Title").tag(SortKey.title)
                    Text("Project").tag(SortKey.project)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                controlPill(
                    icon: "arrow.up.arrow.down",
                    text: sort == .due ? "Due date"
                        : sort == .title ? "Title" : "Project"
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")
            if !projects.isEmpty {
                Menu {
                    Picker("Project", selection: $filterProject) {
                        Text("All projects").tag(String?.none)
                        ForEach(projects, id: \.self) { project in
                            Text(project).tag(String?.some(project))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    controlPill(
                        icon: "line.3.horizontal.decrease",
                        text: filterProject ?? "All projects"
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter by project")
            }
            Spacer(minLength: 0)
        }
    }

    private func controlPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.buttonFill))
        .overlay(Capsule().strokeBorder(Theme.buttonStroke, lineWidth: 1))
        .contentShape(Capsule())
    }

    private func card(_ item: TrackedItem, attention: Bool) -> some View {
        TrackedCard(
            item: item,
            days: store.daysUntil(item),
            attention: attention,
            onDone: { store.markDone(item.id) },
            onPostpone: { months, days in
                store.postpone(item.id, byMonths: months, byDays: days)
            },
            onRemove: { store.remove(item.id) }
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.heading)
            .padding(.leading, 2)
            .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No reminders yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Tell Claude to \u{201C}track the client secret expiry in "
                + "24 months\u{201D}, or add one here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: - Manual add

    private var addButton: some View {
        QuietCardButton {
            withAnimation(.easeOut(duration: 0.15)) { adding = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Track something")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formField("What needs doing?", text: $newTitle, size: 12.5, height: 28)
            CalendarGrid(selection: $newDue)
            HStack(spacing: 8) {
                remindMenu
                Spacer(minLength: 0)
            }
            formField("Project (optional)", text: $newProject)
            formField("Notes (optional)", text: $newNotes)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismissForm() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Button(action: save) {
                    Text("Track")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.buttonActiveStroke)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.buttonActiveFill))
                        .overlay(
                            Capsule().strokeBorder(
                                Theme.buttonActiveStroke.opacity(0.5),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    newTitle.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.buttonFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
    }

    /// An inset text field: recessed fill and hairline, so inputs read as
    /// fields rather than loose text on the card.
    private func formField(
        _ placeholder: String,
        text: Binding<String>,
        size: CGFloat = 11,
        height: CGFloat = 26
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.buttonStroke, lineWidth: 1)
            )
    }

    /// The lead-time control as an unmistakable pull-down button: label,
    /// value, and the HIG's up/down disclosure chevrons.
    private var remindMenu: some View {
        Menu {
            Button("1 week before") { newLeadDays = 7 }
            Button("2 weeks before") { newLeadDays = 14 }
            Button("1 month before") { newLeadDays = 30 }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Remind \(leadLabel) before")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.buttonStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var leadLabel: String {
        switch newLeadDays {
        case 7: "1 week"
        case 14: "2 weeks"
        case 30: "1 month"
        default: "\(newLeadDays) days"
        }
    }

    private func save() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        store.add(
            title: title,
            due: newDue,
            project: newProject.trimmingCharacters(in: .whitespaces),
            leadDays: newLeadDays,
            notes: newNotes.trimmingCharacters(in: .whitespaces)
        )
        dismissForm()
    }

    private func dismissForm() {
        withAnimation(.easeOut(duration: 0.15)) { adding = false }
        newTitle = ""
        newProject = ""
        newNotes = ""
        newLeadDays = 30
        newDue = Calendar.current
            .date(byAdding: .month, value: 1, to: Date()) ?? Date()
    }
}

/// One active obligation as a card: title with the countdown pill (actions
/// on hover), the dates line, then notes.
private struct TrackedCard: View {
    let item: TrackedItem
    let days: Int?
    let attention: Bool
    let onDone: () -> Void
    let onPostpone: (_ months: Int, _ days: Int) -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Project tag leads the card; the countdown pill (or, hovered,
            // the actions) holds the opposite corner.
            HStack(alignment: .center, spacing: 8) {
                if let project = item.project {
                    ProjectTag(name: project)
                }
                Spacer(minLength: 8)
                Group {
                    if hovered { actions } else { countdownPill }
                }
                .frame(height: 20)
            }
            Text(item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Text(item.due)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textPath)
            if let notes = item.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.buttonFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }

    private var countdownPill: some View {
        Text(TrackedStore.countdown(days: days))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(pillText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(pillText.opacity(0.12)))
    }

    private var pillText: Color {
        guard let days else { return Theme.textSecondary }
        if days < 0 { return Theme.closeRed }
        return attention ? Color(hex: 0xD97706) : Theme.textSecondary
    }

    private var actions: some View {
        HStack(spacing: 4) {
            ControlIconButton(
                systemName: "checkmark", help: "Mark done", action: onDone
            )
            Menu {
                Button("1 week") { onPostpone(0, 7) }
                Button("1 month") { onPostpone(1, 0) }
                Button("3 months") { onPostpone(3, 0) }
                Button("6 months") { onPostpone(6, 0) }
                Button("1 year") { onPostpone(12, 0) }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.controlChip)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Postpone")
            ControlIconButton(
                systemName: "xmark", help: "Untrack", action: onRemove
            )
        }
    }
}

/// The add form's exposed calendar: one month on the page, chevrons to move,
/// the selected day filled in the accent, and a dot under today. Past days
/// are muted and inert — a new obligation can't already be overdue.
private struct CalendarGrid: View {
    @Binding var selection: Date
    /// First of the displayed month.
    @State private var month = Date()

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(monthName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                yearMenu
                Spacer(minLength: 8)
                chevron("chevron.left") { step(-1) }
                chevron("chevron.right") { step(1) }
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 2), count: 7
                ),
                spacing: 2
            ) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.heading)
                        .frame(height: 14)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 24)
                }
                ForEach(1...daysInMonth, id: \.self) { day in
                    dayCell(day)
                }
                // Pad every month to the same six-week grid, so flipping
                // months never changes the form's height.
                ForEach(0..<(42 - leadingBlanks - daysInMonth), id: \.self) { _ in
                    Color.clear.frame(height: 24)
                }
            }
        }
        .onAppear { month = monthStart(of: selection) }
    }

    /// The year as a quiet pull-down beside the month name — this decade of
    /// futures, which covers any sane obligation horizon.
    private var yearMenu: some View {
        let thisYear = calendar.component(.year, from: Date())
        return Menu {
            ForEach(thisYear...(thisYear + 10), id: \.self) { year in
                Button(String(year)) { setYear(year) }
            }
        } label: {
            HStack(spacing: 2) {
                Text(String(calendar.component(.year, from: month)))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a year")
    }

    private func setYear(_ year: Int) {
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.year = year
        month = calendar.date(from: parts) ?? month
    }

    private func dayCell(_ day: Int) -> some View {
        let date = calendar.date(
            byAdding: .day, value: day - 1, to: monthStart(of: month)
        ) ?? month
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(date)
        let isPast = date < calendar.startOfDay(for: Date()) && !isToday
        return Button {
            selection = date
        } label: {
            // Number dead-center in the cell (and so in the selection
            // circle); the today-dot overlays the bottom edge instead of
            // stacking, which pushed the number off-center.
            Text("\(day)")
                .font(.system(
                    size: 10.5,
                    weight: isSelected || isToday ? .semibold : .regular
                ))
                .foregroundStyle(
                    isSelected ? .white
                        : isPast ? Theme.textPath : Theme.text
                )
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    Circle()
                        .fill(isSelected ? Theme.buttonActiveStroke : .clear)
                        .frame(width: 24, height: 24)
                )
                .overlay(alignment: .bottom) {
                    if isToday {
                        Circle()
                            .fill(isSelected ? .white : Theme.buttonActiveStroke)
                            .frame(width: 3, height: 3)
                            .offset(y: -2.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPast)
    }

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Theme.controlChip)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func step(_ by: Int) {
        month = calendar.date(byAdding: .month, value: by, to: month) ?? month
    }

    private func monthStart(of date: Date) -> Date {
        calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ) ?? date
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: month)
    }

    /// Weekday headers rotated to the user's first-weekday setting.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: monthStart(of: month))?.count ?? 30
    }

    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: monthStart(of: month))
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The card's project marker: name on a subtle color wash, the hue picked
/// deterministically from the name so a project keeps its color across
/// launches without anyone assigning one.
private struct ProjectTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .lineLimit(1)
    }

    private var color: Color {
        let palette: [UInt32] = [
            0x3B82F6, 0x16A34A, 0xD97706, 0x8B5CF6, 0xDB2777, 0x0D9488,
        ]
        // djb2 over scalars — Swift's hashValue is launch-seeded, and a tag
        // that changes color every launch reads as a different project.
        var hash: UInt32 = 5381
        for scalar in name.unicodeScalars {
            hash = hash &* 33 &+ scalar.value
        }
        return Color(hex: palette[Int(hash % UInt32(palette.count))])
    }
}

/// A done item, muted: struck title, finish date, restore / delete on hover.
private struct TrackedDoneCard: View {
    let item: TrackedItem
    let onRestore: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .strikethrough(true, color: Theme.heading)
                    .lineLimit(1)
                if let doneAt = item.doneAt {
                    Text("done \(doneAt)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPath)
                }
            }
            Spacer(minLength: 4)
            if hovered {
                ControlIconButton(
                    systemName: "arrow.uturn.backward",
                    help: "Restore",
                    action: onRestore
                )
                ControlIconButton(
                    systemName: "trash", help: "Delete", action: onRemove
                )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.buttonFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}

/// A quiet full-width card-shaped button — dashed intent without the dash.
struct QuietCardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.buttonStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Small square icon control on a row or card.
struct ControlIconButton: View {
    let systemName: String
    let help: String
    /// No resting chrome — the glyph sits bare, hover still fills.
    var bare = false
    /// Round background of this size instead of the 20pt rounded square.
    var circleSize: CGFloat? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // ZStack, not `.background` on the glyph: the chrome fills the
            // fixed frame and the glyph centers in the same frame, so the
            // two can never drift apart.
            ZStack {
                chrome
                // 12pt, not 11: an odd-sized glyph centered in an even
                // frame straddles the pixel grid and reads off-center.
                Image(systemName: systemName)
                    .font(.system(size: circleSize == nil ? 9 : 12, weight: .semibold))
                    .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
            }
            .frame(width: circleSize ?? 20, height: circleSize ?? 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }

    /// Resting chip (unless `bare`), the hover wash layered on top — never
    /// a swap, so hovering always steps the fill up.
    @ViewBuilder
    private var chrome: some View {
        if circleSize != nil {
            ZStack {
                if !bare { Circle().fill(Theme.controlChip) }
                if hovered { Circle().fill(Theme.rowHovered) }
            }
        } else {
            ZStack {
                if !bare { RoundedRectangle(cornerRadius: 5).fill(Theme.controlChip) }
                if hovered { RoundedRectangle(cornerRadius: 5).fill(Theme.rowHovered) }
            }
        }
    }
}
