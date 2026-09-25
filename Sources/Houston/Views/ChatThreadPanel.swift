import SwiftUI

/// Inline chat threads (2026-09-19): ask about ONE paragraph of a reply
/// without losing your place in it, Slack-style. A thread turn is a normal
/// turn into the SAME session, prefixed with a marker quoting the anchored
/// paragraph — the model sees what's referenced, the transcript keeps the
/// exchange on disk (no sidecar), and the UI routes marker-prefixed
/// exchanges into the thread panel instead of the main flow. Same pattern
/// as the handoff prefix-collapse: sent to the model, filtered from view.
enum ChatThread {
    static let markerPrefix = "[Re: \""
    private static let markerClose = "\"]"

    /// Marker-safe form of any quoted text: one line, double quotes
    /// swapped for singles, so the marker's `"]` terminator parses
    /// unambiguously — also the form containment matching runs in.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The anchor key for a quote (a whole paragraph, or any selected
    /// run of text): normalized and capped at 90 chars.
    static func anchorKey(for text: String) -> String {
        let key = normalize(text)
        return key.count > 90 ? String(key.prefix(90)) : key
    }

    /// Containment-matching form: the captured selection is RENDERED
    /// prose, but block text is markdown SOURCE — bold markers, code
    /// backticks, and link targets must come off both sides or a styled
    /// paragraph never matches its own selection. Singles (*, _) are
    /// left alone: mid-word underscores are real text, and a missed
    /// italic match only costs a pill.
    static func matchable(_ text: String) -> String {
        var out = normalize(text)
        // [label](url) → label
        while let range = out.range(
            of: #"\[([^\]]+)\]\([^)]*\)"#, options: .regularExpression
        ) {
            let link = String(out[range])
            let label = link
                .drop(while: { $0 == "[" })
                .prefix(while: { $0 != "]" })
            out.replaceSubrange(range, with: label)
        }
        for token in ["**", "__", "`", "~~", "###", "##", "#"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        return out
    }

    /// Where a quote sits in a paragraph's markdown SOURCE, so the
    /// paragraph can be split around it and the reply chip drawn under
    /// the quoted words themselves. The anchor is normalized rendered
    /// text (quotes flattened to singles, whitespace collapsed, styling
    /// stripped), so the match is tolerant: any run of whitespace, either
    /// quote glyph, and markdown tokens (`**`, `__`, backticks, `~~`,
    /// link brackets/targets) allowed between characters. nil when the
    /// quote can't be located (a stale anchor, or one that crossed a
    /// block boundary) — the caller falls back to a paragraph chip.
    static func rawRange(of anchor: String, in text: String) -> Range<String.Index>? {
        let needle = normalize(anchor)
        guard !needle.isEmpty else { return nil }
        let between = #"(?:\*\*|__|`|~~|\[|\]\([^)]*\))*"#
        var pieces: [String] = []
        var lastWasSpace = false
        for ch in needle {
            if ch.isWhitespace {
                if !lastWasSpace { pieces.append(#"\s+"#) }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            if ch == "'" {
                pieces.append(#"["'‘’“”]"#)
            } else {
                pieces.append(NSRegularExpression.escapedPattern(for: String(ch)))
            }
        }
        let pattern = pieces.joined(separator: between)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole) else { return nil }
        return Range(match.range, in: text)
    }

    /// The paragraph a quote lives in — anchors from arbitrary selections
    /// hang their reply chips off whichever assistant paragraph CONTAINS
    /// the quote. nil when no paragraph matches (a stale quote, or a
    /// selection that spanned blocks).
    static func blockKey(
        containing anchor: String, in messages: [ChatMessage]
    ) -> String? {
        let needle = matchable(anchor)
        guard !needle.isEmpty else { return nil }
        for message in messages where message.role == .assistant {
            for block in message.blocks {
                if case let .text(text) = block,
                   matchable(text).contains(needle) {
                    return anchorKey(for: text)
                }
            }
        }
        return nil
    }

    /// Reply chips per paragraph: each anchor's count attached to the
    /// block key of the paragraph containing it, sorted for stable order.
    static func blockThreads(
        counts: [String: Int], in messages: [ChatMessage]
    ) -> [String: [(anchor: String, count: Int)]] {
        guard !counts.isEmpty else { return [:] }
        var out: [String: [(anchor: String, count: Int)]] = [:]
        for (anchor, count) in counts {
            guard let key = blockKey(containing: anchor, in: messages)
            else { continue }
            out[key, default: []].append((anchor, count))
        }
        for key in out.keys {
            out[key]?.sort { $0.anchor < $1.anchor }
        }
        return out
    }

    /// The window's current text selection. SwiftUI's selectable Text is
    /// backed by an AppKit text layer — when that layer is the first
    /// responder, its selected range is readable DIRECTLY, which is the
    /// reliable path. The pasteboard round-trip below stays as fallback.
    @MainActor
    static func capturedSelection() -> String? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            let range = textView.selectedRange()
            if range.length > 0,
               range.location + range.length <= (textView.string as NSString).length {
                let text = (textView.string as NSString).substring(with: range)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return text
                }
            }
        }
        return pasteboardCapturedSelection()
    }

    /// Fallback capture without disturbing the user's clipboard:
    /// deep-copy the pasteboard, drive the focused responder's copy:,
    /// read the result, put the original back.
    @MainActor
    private static func pasteboardCapturedSelection() -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let before = pasteboard.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        // changeCount unmoved = nothing had a selection to copy.
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return text
    }

    static func compose(anchor: String, question: String) -> String {
        markerPrefix + anchor + markerClose + " " + question
    }

    /// The anchor a thread turn references — nil for normal messages.
    static func anchor(ofUserText text: String) -> String? {
        guard text.hasPrefix(markerPrefix),
              let close = text.range(of: markerClose) else { return nil }
        let start = text.index(text.startIndex, offsetBy: markerPrefix.count)
        guard start <= close.lowerBound else { return nil }
        return String(text[start..<close.lowerBound])
    }

    /// The question after the marker.
    static func question(ofUserText text: String) -> String? {
        guard anchor(ofUserText: text) != nil,
              let close = text.range(of: markerClose) else { return nil }
        return String(text[close.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func anchor(of message: ChatMessage) -> String? {
        guard message.role == .user else { return nil }
        for block in message.blocks {
            if case let .text(text) = block { return anchor(ofUserText: text) }
        }
        return nil
    }

    /// The main transcript without thread exchanges: each marker-prefixed
    /// user message and the assistant reply that follows it drop out.
    static func strippingExchanges(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var skippingReply = false
        for message in messages {
            if anchor(of: message) != nil {
                skippingReply = true
                continue
            }
            if skippingReply {
                if message.role == .assistant { continue }
                skippingReply = false
            }
            out.append(message)
        }
        return out
    }

    /// One anchor's exchanges, marker stripped from the questions.
    static func exchanges(
        in messages: [ChatMessage], anchor target: String
    ) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var collecting = false
        for message in messages {
            if let found = anchor(of: message) {
                collecting = found == target
                if collecting, let text = firstText(message),
                   let question = question(ofUserText: text) {
                    out.append(ChatMessage(
                        id: message.id, role: .user, blocks: [.text(question)]
                    ))
                }
                continue
            }
            if collecting, message.role == .assistant {
                out.append(message)
                continue
            }
            collecting = false
        }
        return out
    }

    /// Reply counts per anchor — the transcript chips.
    static func counts(in messages: [ChatMessage]) -> [String: Int] {
        var out: [String: Int] = [:]
        for message in messages {
            if let anchor = anchor(of: message) {
                out[anchor, default: 0] += 1
            }
        }
        return out
    }

    private static func firstText(_ message: ChatMessage) -> String? {
        for block in message.blocks {
            if case let .text(text) = block { return text }
        }
        return nil
    }
}

/// Everything the thread panel needs to stand alone — carried in the
/// RightPanel case so the panel keeps working even if the chat behind it
/// navigates away (the session hub can resume the file regardless).
struct ChatThreadTarget: Equatable, Hashable {
    let project: String
    let file: String
    let harnessRaw: String
    let anchor: String

    var harness: ChatHarness { ChatHarness(rawValue: harnessRaw) ?? .claude }
    var ref: ChatSessionRef {
        ChatSessionRef(
            harness: harness, filePath: file, title: "", modified: .distantPast
        )
    }
}

extension Notification.Name {
    /// Open the thread panel for one reply paragraph. userInfo: project,
    /// file, harness (raw), anchor.
    static let houstonOpenChatThread = Notification.Name("houstonOpenChatThread")
    /// Edit ▸ Ask About Selection (⇧⌘A): thread the current text
    /// selection. The open transcript's view resolves and validates it.
    static let houstonAskSelection = Notification.Name("houstonAskSelection")
    /// Edit ▸ Add Selection to Tasks (⌘S): save the current text
    /// selection as a task and open the tasks menu.
    static let houstonAddSelectionToTasks =
        Notification.Name("houstonAddSelectionToTasks")
}

/// The right-sheet thread view: the quoted anchor on top, that anchor's
/// exchanges under it, a small composer at the bottom. Sends go into the
/// SAME session the chat runs on, marker-prefixed.
struct ChatThreadPanel: View {
    let target: ChatThreadTarget

    @ObservedObject private var hub = ChatSessionHub.shared
    @State private var exchanges: [ChatMessage] = []
    @State private var question = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        anchorQuote
                        if exchanges.isEmpty, hub.sessions[target.file] == nil {
                            Text("Ask about this part — the answer lands here, "
                                + "and the main conversation stays put.")
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(exchanges) { message in
                            MessageView(
                                message: message, harness: target.harness,
                                showTools: false
                            )
                        }
                        if let session = hub.sessions[target.file] {
                            ThreadLiveSection(
                                session: session,
                                anchor: target.anchor,
                                harness: target.harness,
                                onGrow: {
                                    proxy.scrollTo("thread-bottom", anchor: .bottom)
                                },
                                onTurnEnd: { reload() }
                            )
                        }
                        Color.clear.frame(height: 1).id("thread-bottom")
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            composer
        }
        .task(id: target.file + "|" + target.anchor) { reload() }
    }

    /// The paragraph this thread hangs off — a quote card with the rose bar.
    private var anchorQuote: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.buttonActiveStroke)
                .frame(width: 3)
            Text(target.anchor)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Theme.buttonFill.opacity(0.4))
        )
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Reply in thread…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit(send)
            Button(action: send) {
                LucideIcon("arrow-up", size: 13)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.ctaFill))
            }
            .buttonStyle(.plain)
            .disabled(trimmedQuestion.isEmpty)
            .opacity(trimmedQuestion.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .fill(Theme.gitPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
        .padding(.top, 8)
        .onAppear { inputFocused = true }
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let q = trimmedQuestion
        guard !q.isEmpty else { return }
        question = ""
        let session = hub.session(for: target.ref, project: target.project)
        session.send(
            text: ChatThread.compose(anchor: target.anchor, question: q),
            model: session.lastModel
                ?? ChatModelChoice.fallback(for: target.harness)
        )
    }

    /// Cached parse first for an instant paint, real read after.
    private func reload() {
        let ref = target.ref
        let anchor = target.anchor
        if let cached = ChatArchive.cachedTranscript(ref) {
            exchanges = ChatThread.exchanges(in: cached, anchor: anchor)
        }
        Task.detached(priority: .userInitiated) {
            let parsed = ChatArchive.transcript(ref)
            let fresh = ChatThread.exchanges(in: parsed, anchor: anchor)
            await MainActor.run { exchanges = fresh }
        }
    }
}

/// The thread's live turn: renders the streaming exchange when the
/// session's in-flight turn belongs to THIS anchor, and re-reads the
/// transcript when it lands. The turn-end reload retries once — the
/// transcript flush can lag the running flip.
private struct ThreadLiveSection: View {
    @ObservedObject var session: ChatAgentSession
    let anchor: String
    let harness: ChatHarness
    var onGrow: () -> Void = {}
    let onTurnEnd: () -> Void

    private var isOurs: Bool {
        session.pendingUserText
            .flatMap { ChatThread.anchor(ofUserText: $0) } == anchor
    }

    var body: some View {
        Group {
            if isOurs {
                if let pending = session.pendingUserText,
                   let question = ChatThread.question(ofUserText: pending) {
                    MessageView(
                        message: ChatMessage(
                            role: .user, blocks: [.text(question)]
                        ),
                        harness: harness
                    )
                }
                if !session.liveBlocks.isEmpty {
                    MessageView(
                        message: ChatMessage(
                            role: .assistant, blocks: session.liveBlocks
                        ),
                        harness: harness
                    )
                }
                if !session.streamText.isEmpty {
                    MessageView(
                        message: ChatMessage(
                            role: .assistant,
                            blocks: [.text(session.streamText)]
                        ),
                        harness: harness
                    )
                }
                if session.running {
                    // Same indicator as the main live turn: the liquid
                    // blob, plus the thinking token count when the model
                    // is in an extended-thinking block.
                    HStack(spacing: 10) {
                        LiquidThinkingView()
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        Group {
                            if let tokens = session.thinkingTokens {
                                Text(tokens > 0
                                    ? "Thinking… \(formatTokens(tokens)) tokens"
                                    : "Thinking…")
                            } else {
                                Text("Working…")
                            }
                        }
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    }
                    .padding(.leading, -9)
                }
            }
        }
        .onChange(of: session.streamText) { _, _ in onGrow() }
        .onChange(of: session.running) { was, running in
            guard was, !running else { return }
            onTurnEnd()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onTurnEnd() }
        }
    }
}
