import SwiftUI

/// A run of consecutive tool calls in a reply (2026-10-21). One call
/// renders as its own row; two or more fold into a "N steps" disclosure
/// (a long stretch of Bash/Read/Edit rows buried the prose between them,
/// 2026-09-17), each step its own expandable `ToolCallView` once open.
/// The task list is the one kind that stays open on its own — it IS the
/// content, like the desktop app's plan card.
struct ToolRunView: View {
    let calls: [ToolCall]
    @Binding var expanded: Bool
    var dimmed = false

    private var running: Bool { calls.contains { $0.status == .running } }
    private var failed: Int { calls.filter { $0.status == .failed }.count }
    private var edits: (added: Int, removed: Int) {
        calls.reduce((0, 0)) { acc, call in
            guard let counts = call.changeCounts else { return acc }
            return (acc.0 + counts.added, acc.1 + counts.removed)
        }
    }

    var body: some View {
        if calls.count == 1 {
            ToolCallView(call: calls[0])
                .opacity(dimmed ? 0.8 : 1)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        LucideIcon("chevron-right", size: 10)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        if running {
                            ToolPulse()
                        } else {
                            LucideIcon("wrench", size: 12)
                        }
                        Text("\(calls.count) steps")
                        if failed > 0 {
                            Text("· \(failed) failed").foregroundStyle(Theme.textDanger)
                        }
                        let counts = edits
                        if counts.added > 0 || counts.removed > 0 {
                            DiffCounts(added: counts.added, removed: counts.removed)
                        }
                        // Collapsed, the latest step's title says where
                        // the work is.
                        if !expanded, let last = calls.last {
                            Text("· " + last.title)
                                .lineLimit(1)
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        }
                    }
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide the steps" : "Show the steps")
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(calls) { call in
                            ToolCallView(call: call)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
            .opacity(dimmed ? 0.8 : 1)
        }
    }
}

/// One tool call: a row (icon, title, change counts or the command,
/// status) that opens into the kind's body — a diff for an edit, the
/// output for a shell command, the excerpt for a read, the checklist
/// for a plan update, the plan for ExitPlanMode. Works from whatever
/// fields the harness filled: with none beyond a title it is a chip.
struct ToolCallView: View {
    let call: ToolCall
    @State private var open: Bool
    @State private var hovered = false

    init(call: ToolCall) {
        self.call = call
        // Checklists open by default; everything else is a row until
        // clicked.
        _open = State(initialValue: call.kind == .todo && !call.todos.isEmpty)
    }

    private var hasBody: Bool {
        call.diff != nil || call.output != nil || call.content != nil
            || !call.todos.isEmpty || !call.questions.isEmpty || call.command != nil
    }

    static func icon(for kind: ToolCall.Kind) -> String {
        switch kind {
        case .read: "file-text"
        case .edit: "square-pen"
        case .write: "file-plus"
        case .shell: "square-terminal"
        case .search: "search"
        case .fetch: "globe"
        case .agent: "compass"
        case .todo: "list-checks"
        case .question: "message-square-text"
        case .plan: "list-ordered"
        case .skill: "zap"
        case .think: "brain"
        case .other: "wrench"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasBody else { return }
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if call.status == .running {
                        ToolPulse()
                    } else if call.status == .failed {
                        LucideIcon("circle-x", size: 12).foregroundStyle(Theme.textDanger)
                    } else {
                        LucideIcon(Self.icon(for: call.kind), size: 12)
                    }
                    Text(call.title)
                        .lineLimit(1)
                    if let counts = call.changeCounts, counts.added + counts.removed > 0 {
                        DiffCounts(added: counts.added, removed: counts.removed)
                    } else if call.kind == .shell, let command = call.command, !open {
                        Text(ChatArchive.condense(command))
                            .font(Theme.Fonts.monoSmall)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    } else if !call.detail.isEmpty, call.kind != .shell {
                        Text(call.detail)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    }
                    if hasBody {
                        LucideIcon("chevron-right", size: 10)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .opacity(hovered || open ? 1 : 0.4)
                    }
                }
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(call.filePath ?? call.command ?? call.detail)
            if open {
                ToolCallBody(call: call)
                    .padding(.leading, 18)
            }
        }
    }
}

/// The kind-specific body under a tool row.
struct ToolCallBody: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch call.kind {
            case .edit, .write:
                if let diff = call.diff {
                    DiffView(diff: diff, path: call.filePath)
                }
                if let output = call.output, call.isError {
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: true)
                } else if let output = call.output, call.diff == nil {
                    // A harness that gave a unified diff as text (codex).
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: false)
                }
            case .shell:
                if let command = call.command {
                    CodeCardLite(text: command, label: "command")
                }
                if let output = call.output {
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: call.isError)
                } else if call.status == .done {
                    Text("No output")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            case .todo:
                if !call.todos.isEmpty {
                    TodoListView(items: call.todos)
                } else if let output = call.output {
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: call.isError)
                }
            case .question:
                QuestionSummary(questions: call.questions, answer: call.output)
            case .plan:
                if let plan = call.content, !plan.isEmpty {
                    MarkdownBlockView(text: plan, color: Theme.chatProse)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                                .fill(Theme.attachedWellFill)
                        )
                }
                if let output = call.output {
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: call.isError)
                }
            case .think:
                if let text = call.content {
                    Text(text)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                if let prompt = call.content, call.kind == .agent {
                    Text(prompt)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                if let output = call.output {
                    ToolOutputBlock(text: output, truncated: call.outputTruncated, isError: call.isError)
                } else if call.status == .done, call.content == nil {
                    Text(call.kind == .read ? "Empty file" : "No output")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "+12 −3".
struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)").foregroundStyle(Theme.textPositive)
            }
            if removed > 0 {
                Text("−\(removed)").foregroundStyle(Theme.textDanger)
            }
        }
        .font(Theme.Fonts.monoSmall)
        .monospacedDigit()
    }
}

/// A unified diff: hunk lines on added/removed washes, old and new line
/// numbers in the gutter. Wraps long lines rather than scrolling
/// sideways — a code card you can read in the column.
struct DiffView: View {
    let diff: FileDiff
    var path: String? = nil
    /// Lines shown before "Show all" — a 400-line rewrite shouldn't
    /// unroll into the transcript.
    private let foldAt = 60
    @State private var showAll = false

    private var total: Int { diff.hunks.reduce(0) { $0 + $1.lines.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path {
                HStack(spacing: 6) {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    DiffCounts(added: diff.added, removed: diff.removed)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Rectangle().fill(Theme.buttonStroke).frame(height: 1)
            }
            let folded = foldedHunks
            ForEach(Array(folded.enumerated()), id: \.offset) { index, hunk in
                if index > 0 {
                    Rectangle().fill(Theme.buttonStroke).frame(height: 1)
                }
                hunkView(hunk)
            }
            if !showAll, total > foldAt {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAll = true }
                } label: {
                    Text("Show all \(total) lines")
                        .font(Theme.Fonts.secondaryMedium)
                        .foregroundStyle(Theme.link)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Row: Identifiable {
        let line: FileDiff.Line
        let old: Int?
        let new: Int?
        var id: Int { line.id }
    }

    private struct FoldedHunk {
        let rows: [Row]
        let numbered: Bool
    }

    /// Hunks as gutter-numbered rows, cut at the fold until "Show all".
    private var foldedHunks: [FoldedHunk] {
        var budget = showAll ? Int.max : foldAt
        var out: [FoldedHunk] = []
        for hunk in diff.hunks {
            guard budget > 0 else { break }
            var oldLine = hunk.oldStart
            var newLine = hunk.newStart
            var rows: [Row] = []
            for line in hunk.lines {
                guard budget > 0 else { break }
                budget -= 1
                switch line.kind {
                case .context:
                    rows.append(Row(line: line, old: oldLine, new: newLine)); oldLine += 1; newLine += 1
                case .removed:
                    rows.append(Row(line: line, old: oldLine, new: nil)); oldLine += 1
                case .added:
                    rows.append(Row(line: line, old: nil, new: newLine)); newLine += 1
                }
            }
            out.append(FoldedHunk(rows: rows, numbered: hunk.oldStart > 0))
        }
        return out
    }

    private func hunkView(_ hunk: FoldedHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.rows) { row in
                HStack(alignment: .top, spacing: 0) {
                    if hunk.numbered {
                        Text(row.old.map(String.init) ?? "")
                            .frame(width: 34, alignment: .trailing)
                        Text(row.new.map(String.init) ?? "")
                            .frame(width: 34, alignment: .trailing)
                            .padding(.trailing, 8)
                    }
                    Text(row.line.kind == .added ? "+" : (row.line.kind == .removed ? "−" : " "))
                        .frame(width: 12, alignment: .leading)
                    Text(row.line.text.isEmpty ? " " : row.line.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(for: row.line.kind))
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(wash(for: row.line.kind))
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .context: Theme.textSecondary
        case .added: Theme.textPositive
        case .removed: Theme.textDanger
        }
    }

    private func wash(for kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: Theme.textPositive.opacity(0.1)
        case .removed: Theme.textDanger.opacity(0.1)
        }
    }
}

/// A tool's textual output: mono, capped at a fold with "Show all",
/// red when the tool failed.
struct ToolOutputBlock: View {
    let text: String
    var truncated = false
    var isError = false
    private let foldAt = 40
    @State private var showAll = false

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        let all = lines
        let shown = showAll ? all : Array(all.prefix(foldAt))
        VStack(alignment: .leading, spacing: 4) {
            Text(shown.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isError ? Theme.textDanger : Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if all.count > shown.count || (showAll && truncated) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAll = true }
                } label: {
                    Text(showAll
                        ? "Output truncated at \(ToolCall.outputCap / 1000)k characters"
                        : "Show all \(all.count) lines")
                        .font(Theme.Fonts.secondaryMedium)
                        .foregroundStyle(showAll ? Theme.textSecondary : Theme.link)
                }
                .buttonStyle(.plain)
                .disabled(showAll)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-line labelled mono block (the command a shell step ran).
struct CodeCardLite: View {
    let text: String
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            CopyIconButton(text: text, help: "Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The agent's checklist (TodoWrite), like the desktop app's plan card.
struct TodoListView: View {
    let items: [ToolCall.TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch item.state {
                    case .completed:
                        LucideIcon("circle-check", size: 13).foregroundStyle(Theme.textPositive)
                    case .inProgress:
                        LucideIcon("circle", size: 13).foregroundStyle(Theme.link)
                    case .pending:
                        LucideIcon("circle", size: 13).foregroundStyle(Theme.textSecondary.opacity(0.5))
                    }
                    Text(item.content)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(item.state == .completed ? Theme.textSecondary : Theme.chatProse)
                        .strikethrough(item.state == .completed, color: Theme.textSecondary.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A finished AskUserQuestion: each question with the options offered,
/// and what the tool got back.
struct QuestionSummary: View {
    let questions: [ToolCall.Question]
    let answer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.text)
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.chatProse)
                        .fixedSize(horizontal: false, vertical: true)
                    if !question.options.isEmpty {
                        Text(question.options.map(\.label).joined(separator: " · "))
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let answer, !answer.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    LucideIcon("reply", size: 12)
                    Text(answer)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.attachedWellFill))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small breathing dot: a step still running.
struct ToolPulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.link)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .frame(width: 12, height: 12)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}
