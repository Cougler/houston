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
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        A coding assistant just asked the user a question. Reply with \
        ONLY the user's single most likely answer — short and direct, \
        like "Yes, build it" or "Use the first option". Under 8 words, \
        no quotes. Reply with nothing if the question has no obvious \
        short answer.
        """)
        guard let response = try? await session.respond(
            to: "Conversation tail:\n\(context)\n\nThe user's likely reply:"
        ) else { return nil }
        let text = response.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        guard !text.isEmpty, text.count <= 60 else { return nil }
        return text
        #else
        return nil
        #endif
    }

    /// The chat composer's ghost-text autocomplete, same on-device model.
    /// (Claude Code's own TUI autocomplete isn't exposed anywhere, so this
    /// is Houston's equivalent, not a passthrough.)
    static func completeDraft(context: String, draft: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
        You autocomplete a user's partially typed message to a coding \
        assistant. Reply with ONLY the continuation of their text — do not \
        repeat what they already typed, no quotes. Under 15 words. Reply \
        with nothing if there is no natural continuation.
        """)
        guard let response = try? await session.respond(
            to: "Conversation context:\n\(context)\n\nPartial message:\n\(draft)"
        ) else { return nil }
        var text = response.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        if text.hasPrefix(draft) { text = String(text.dropFirst(draft.count)) }
        guard !text.isEmpty, text.count <= 120 else { return nil }
        return text
        #else
        return nil
        #endif
    }

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
