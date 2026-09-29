import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Names chats with Apple's on-device model (macOS 26+): sessions whose
/// heuristic title is weak — a bare command, a single word — get a short
/// generated title from the opening exchange. Titles are cached to disk
/// forever, so each session is named at most once. On systems without the
/// model this is inert and the heuristic titles stand.
@MainActor
final class ChatTitler: ObservableObject {
    static let shared = ChatTitler()

    /// Generated titles by transcript path — overlay on `ChatSessionRef.title`.
    @Published private(set) var titles: [String: String] = [:]

    private var queue: [ChatSessionRef] = []
    private var queued = Set<String>()
    private var running = false

    private static var cacheURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("chat-titles.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([String: String].self, from: data) {
            titles = cached
        }
    }

    func displayTitle(_ ref: ChatSessionRef) -> String {
        titles[ref.filePath] ?? ref.title
    }

    /// A user-chosen name — same overlay the generated titles use, so it
    /// persists and the on-device model never overwrites it.
    func setCustomTitle(_ title: String, for file: String) {
        titles[file] = title
        save()
    }

    /// Queue a session for naming if it needs one. Every listed chat gets
    /// a generated title — the heuristic fallback is the literal first
    /// message, which reads as a fragment, not a name. Serial by design —
    /// one on-device generation at a time, skipping anything already
    /// named (including user renames, which live in the same overlay).
    func ensure(_ ref: ChatSessionRef) {
        guard titles[ref.filePath] == nil,
              !queued.contains(ref.filePath) else { return }
        guard #available(macOS 26.0, *) else { return }
        queued.insert(ref.filePath)
        queue.append(ref)
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let ref = queue.removeFirst()
        Task {
            let snippet = await Task.detached(priority: .utility) {
                ChatArchive.titleSnippet(ref)
            }.value
            var generated: String?
            if #available(macOS 26.0, *), let snippet {
                generated = await Self.generate(snippet)
            }
            if let generated {
                titles[ref.filePath] = generated
                save()
            }
            // A failed generation stays in `queued` so it isn't retried in
            // a loop this run; next launch gets another shot.
            running = false
            pump()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        // A fresh install has no Application Support/Houston yet — without
        // this, titles are silently dropped until another store creates it.
        try? FileManager.default.createDirectory(
            at: Self.cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    /// A mission-log-style handoff brief for cross-harness transplants:
    /// the head of a long conversation compressed into "where things
    /// stand", so the target model picks up without re-reading the whole
    /// transcript. Chunked map-reduce — the on-device model's window is
    /// small. nil when the model is unavailable.
    static func handoffBrief(_ chunks: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available,
              !chunks.isEmpty else { return nil }
        var notes: [String] = []
        for chunk in chunks {
            let session = LanguageModelSession(instructions: """
            You compress part of a coding-assistant conversation. Reply \
            with 2-4 terse bullet points: what was worked on, decisions \
            made, and outcomes. No preamble.
            """)
            if let response = try? await session.respond(to: chunk) {
                notes.append(response.content)
            }
        }
        guard !notes.isEmpty else { return nil }
        let reducer = LanguageModelSession(instructions: """
        You write a handoff brief for a coding session so a new assistant \
        can pick up the work. From the notes, write: 2-3 sentences on \
        where things stand, then a short "Done:" bullet list, then one \
        "In flight:" line for whatever was mid-stream. Terse, concrete, \
        no preamble.
        """)
        guard let final = try? await reducer.respond(
            to: notes.joined(separator: "\n")
        ) else { return nil }
        let brief = final.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return brief.isEmpty ? nil : brief
        #else
        return nil
        #endif
    }

    /// The empty composer's suggested reply, offered only when the
    /// assistant's last message ended in a question — "Yes, build it"
    /// grade, Tab drops it into the prompt for the user to send.
    static func suggestReply(context: String) async -> String? {
        // Cached per conversation tail: the field empties and refills
        // (type, delete, reopen the chat) far more often than the tail
        // changes, and a re-ask made the ghost blink and sometimes flip.
        if let cached = replyCache[context] { return cached }
        let reply = await generateReply(context: context)
        replyCache[context] = reply
        if replyCache.count > 64 { replyCache.removeAll() }
        return reply
    }

    private static var replyCache: [String: String?] = [:]

    private static func generateReply(context: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        You suggest what a user might type next to a coding assistant; it \
        shows as dimmed ghost text in their empty message box. Look at the \
        assistant's LAST message. If it asks the user a question or offers \
        a concrete next step, reply with the user's single most likely \
        short answer, like "Yes, build it", "Use the first option", or \
        "Go ahead and add the tests". Under 8 words, no quotes. If the last \
        message asks nothing and offers nothing (a summary, a status \
        report, a finished answer), reply with exactly NONE.
        """)
        guard let response = try? await session.respond(
            to: "Conversation tail:\n\(context)\n\nThe user's likely reply:"
        ) else { return nil }
        let text = response.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        guard !text.isEmpty, text.count <= 60, !isNone(text),
              isReplyGrounded(text, in: context)
        else { return nil }
        return text
        #else
        return nil
        #endif
    }

    /// The chat composer's ghost-text autocomplete, same on-device model.
    /// (Claude Code's own TUI autocomplete isn't exposed anywhere, so this
    /// is Houston's equivalent, not a passthrough.) Only completions that
    /// refer to something in the conversation survive — see `isGrounded`.
    static func completeDraft(context: String, draft: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        You autocomplete a user's partially typed message to a coding \
        assistant. Only complete it when the rest of their sentence clearly \
        refers to something already in the conversation: a file, feature, \
        bug, option, or name mentioned there. Reply with ONLY the \
        continuation (never repeat what they typed), no quotes, under 12 \
        words, ending where their sentence would end. If you would have to \
        guess, or nothing in the conversation fits, reply with exactly NONE.
        """)
        guard let response = try? await session.respond(
            to: "Conversation:\n\(context)\n\nPartial message:\n\(draft)"
        ) else { return nil }
        var text = response.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        if text.hasPrefix(draft) { text = String(text.dropFirst(draft.count)) }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
              text.count <= 100, !isNone(text),
              isGrounded(text, draft: draft, in: context)
        else { return nil }
        return text
        #else
        return nil
        #endif
    }

    /// A suggested reply may be a bare go-ahead ("Yes, go ahead"), but any
    /// substantive word in it must come from the agent's last message —
    /// "Yes, make it better" under a message about autocomplete named
    /// nothing the agent said.
    private static func isReplyGrounded(_ reply: String, in context: String) -> Bool {
        let lastMessage = context.components(separatedBy: "Assistant: ").last ?? context
        let haystack = lastMessage.lowercased()
        let content = reply.lowercased()
            .split { !($0.isLetter || $0.isNumber || "_-.".contains($0)) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .filter {
                $0.count >= 4 && !groundingStopwords.contains($0)
                    && !affirmations.contains($0)
            }
        return content.isEmpty || content.contains { haystack.contains($0) }
    }

    /// Words a go-ahead is made of — never evidence of anything.
    private static let affirmations: Set<String> = [
        "yes", "yeah", "yep", "sure", "okay", "ahead", "sounds", "perfect",
        "please", "thanks", "thank", "that's", "works", "cool", "nice", "fine",
        "proceed", "continue",
    ]

    private static func isNone(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .uppercased() == "NONE"
    }

    /// Whether a completion refers to the conversation: some content word
    /// of it (joined to the word being typed, when the caret is mid-word)
    /// appears in the context. The model is told the same thing, but it
    /// happily "completes" with generic filler; this is the backstop.
    private static func isGrounded(_ completion: String, draft: String, in context: String) -> Bool {
        let midWord = draft.last.map { !$0.isWhitespace } ?? false
        let fragment = midWord
            ? String(draft.split(whereSeparator: \.isWhitespace).last ?? "") : ""
        let words = (fragment + completion).lowercased()
            .split { !($0.isLetter || $0.isNumber || "_-.".contains($0)) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
        let haystack = context.lowercased()
        return words.contains { word in
            word.count >= 4 && !groundingStopwords.contains(word) && haystack.contains(word)
        }
    }

    /// Common words that appear in any conversation — matching one proves
    /// nothing about the completion being about THIS chat.
    private static let groundingStopwords: Set<String> = [
        "that", "this", "with", "from", "have", "what", "when", "make", "like",
        "just", "also", "should", "would", "could", "there", "their", "then",
        "than", "them", "they", "your", "into", "about", "some", "more", "sure",
        "want", "need", "please", "thanks", "okay", "going", "does", "dont",
        "yeah", "good", "great", "maybe", "which", "where", "will", "been",
        "were", "being", "here", "only", "over", "each", "other", "these",
        "those", "very", "much", "many", "first", "next", "after", "before",
        "because", "while", "again", "still", "even", "well", "back", "same",
        "such", "both", "know", "think", "look", "work", "working", "thing",
        "things", "right", "now", "can't", "it's", "let's", "doesn't",
    ]

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generate(_ snippet: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        You title coding-assistant chat sessions. Reply with ONLY the \
        title: three to six words naming the SPECIFIC work — the feature \
        built, bug fixed, or question answered, with its concrete subject \
        (like "Fix sidebar hover flicker" or "Stripe webhook retries"). \
        Never generic labels like "Coding help", "Project setup", or \
        "Chat session". No quotes, no trailing punctuation.
        """)
        guard let response = try? await session.respond(
            to: "Title this session:\n\n" + snippet
        ) else { return nil }
        var title = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”.,"))
        if let first = title.components(separatedBy: "\n").first { title = first }
        guard !title.isEmpty, title.count <= 60 else { return nil }
        return title
    }
    #else
    @available(macOS 26.0, *)
    private static func generate(_ snippet: String) async -> String? { nil }
    #endif
}

/// One-line on-device previews for the chat's jump dots: hover a dot,
/// see what that part of the conversation is about before jumping.
/// Cached per message id for the app's lifetime; the raw user text
/// stands in until the model answers (and forever without the model).
@MainActor
final class ChatDotPreviewer: ObservableObject {
    static let shared = ChatDotPreviewer()

    @Published private(set) var generated: [String: String] = [:]
    private var pending = Set<String>()

    /// The preview to show right now — generated if ready, the raw text
    /// otherwise — kicking off a generation on first ask.
    func text(for id: String, source: String) -> String {
        if let ready = generated[id] { return ready }
        request(id: id, source: source)
        // Fallback: the user's own words, role marker stripped.
        let flat = source
            .replacingOccurrences(of: "User: ", with: "")
            .split(separator: "\n").first.map(String.init) ?? source
        return String(flat.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
    }

    private func request(id: String, source: String) {
        guard !pending.contains(id) else { return }
        guard #available(macOS 26.0, *) else { return }
        pending.insert(id)
        Task {
            if let text = await Self.generate(source) {
                generated[id] = text
            }
            // A failed generation stays pending — no retry loop while
            // the pointer sits on the dot.
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generate(_ source: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available
        else { return nil }
        let session = LanguageModelSession(instructions: """
        You write a tiny index label for one exchange in a coding \
        conversation, so the user can spot it while scrubbing through \
        the chat. Reply with ONLY the label: a specific noun phrase, \
        3-6 words, capturing the exchange's SUBJECT — the feature, bug, \
        file, or decision — not the fact that it was discussed. \
        Sentence case, no quotes, no trailing period. Never start with \
        "User", "The user", "Discussion", "Conversation", "Question", \
        "Request", or "Asking". Good labels: "Fixing the composer drop \
        crash", "Server popover redesign", "Context rollover threshold", \
        "Why chat felt slower than terminal".
        """)
        guard let response = try? await session.respond(to: source)
        else { return nil }
        var text = response.content
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`.,: "))
        // Belt and suspenders on the banned openers — the small model
        // slips sometimes, and a meta label is worse than raw text.
        for banned in ["the user ", "user ", "discussion of ", "question about ",
                       "conversation about ", "asking about ", "request to "] {
            if text.lowercased().hasPrefix(banned) {
                text = String(text.dropFirst(banned.count))
            }
        }
        guard !text.isEmpty, text.count <= 60,
              !text.lowercased().contains("exchange"),
              !text.lowercased().contains("label")
        else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    #else
    @available(macOS 26.0, *)
    private static func generate(_ source: String) async -> String? { nil }
    #endif
}
