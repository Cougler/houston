import Foundation

/// A sealed chat — the object an inactive conversation collapses into.
/// Deliberately just metadata + the pointer: the transcript file on disk
/// IS the content, so the capsule view renders it live and the reference
/// marker hands the agent the path to read. Sealing never touches the
/// transcript, so reopening is just deleting the capsule.
struct ChatCapsule: Codable, Identifiable, Hashable {
    let id: String
    let project: String
    /// The raw transcript on disk — everything the capsule "contains".
    let sourceFile: String
    /// `ChatHarness.rawValue` of the CLI that wrote the chat.
    let harness: String
    var title: String
    let sealedAt: Date

    /// The chip's label — capsules render as an icon + a short title.
    var shortTitle: String {
        title.count > 18 ? String(title.prefix(17)) + "…" : title
    }

    /// The line attaching this capsule to a message. The `[Capsule "…" @
    /// …]` head is the render marker — transcripts collapse the whole
    /// line to a chip (`ChatArchive.userBlocks`) while the model keeps
    /// the path and the instruction.
    var referenceText: String {
        let safe = shortTitle.replacingOccurrences(of: "\"", with: "'")
        return "[Capsule \"\(safe)\" @ \(sourceFile)] An earlier chat from "
            + "this project, attached as context — its full transcript is at "
            + "that path; read or grep it for specifics when needed."
    }
}

extension Notification.Name {
    /// Reference text for the chat composer to append to its draft —
    /// posted by the capsule view's insert buttons (`object` is the
    /// String). Drags land directly via onDrop instead.
    static let houstonComposerInsert = Notification.Name("houstonComposerInsert")
    /// A drop resolved off-main stages into the composer. userInfo:
    /// "path" (file to attach) or "text" (to stage). The completion
    /// closures must not touch the composer directly — see the
    /// NSItemProvider gotcha in CLAUDE.md.
    static let houstonComposerStageDrop = Notification.Name("houstonComposerStageDrop")
    /// Stage a capsule as a composer attachment chip (`object` is the
    /// `ChatCapsule`).
    static let houstonComposerAttachCapsule = Notification.Name("houstonComposerAttachCapsule")
    /// Open a capsule's transcript in the right sheet (`object` is the
    /// capsule's source-file path) — posted by chips in chat transcripts.
    static let houstonOpenCapsule = Notification.Name("houstonOpenCapsule")
    /// A chat continued under a new transcript file (context rollover,
    /// cross-harness transplant) — `userInfo` carries "project"/"file".
    /// The main window retargets `chatTarget` so the sidebar highlight
    /// follows the conversation instead of pointing at the sealed file.
    static let houstonChatRekeyed = Notification.Name("houstonChatRekeyed")
}

/// The capsule shelf, persisted to
/// `Application Support/Houston/capsules.json`. Sealing is a metadata
/// write — instant and free — because a capsule carries no copied
/// content, only the pointer. Chats seal automatically once inactive
/// (`MainWindowView.autoSeal`); the sidebar ✕ seals one on the spot.
@MainActor
final class CapsuleStore: ObservableObject {
    static let shared = CapsuleStore()

    @Published private(set) var capsules: [ChatCapsule] = []

    /// The chat currently on screen (set by the main window) — the sweep
    /// never seals it out from under the user.
    var activeChatFile: String?

    /// Mirror of `capsules` by source file — `isSealed` runs per sidebar
    /// row per render, so it must not scan the array.
    private var sealedFiles: Set<String> = []
    /// Trivial chats (a skill run canceled at the prompt — no assistant
    /// output) leave the sidebar WITHOUT becoming capsules: dismissed,
    /// not sealed. Persisted so they don't resurface every launch; the
    /// transcript on disk is never touched.
    @Published private(set) var dismissedFiles: Set<String> = []
    private var saveScheduled = false

    /// Quiet period before a session is even considered for dismissal —
    /// a chat mid-first-exchange must never be judged negligible.
    static let dismissAfterQuiet: TimeInterval = 30 * 60

    private static var fileURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("capsules.json")
    }
    private static var dismissedURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("dismissed-chats.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([ChatCapsule].self, from: data) {
            capsules = stored
            sealedFiles = Set(stored.map(\.sourceFile))
        }
        if let data = try? Data(contentsOf: Self.dismissedURL),
           let stored = try? JSONDecoder().decode(Set<String>.self, from: data) {
            dismissedFiles = stored
        }
        // The dismissal heartbeat. Chats are FOREVER in the sidebar now
        // (2026-09-14, the ChatGPT mental model) — the sweep's only job
        // is hiding sessions too slight to be conversations: canceled
        // skill runs, one-line terminal Q&As. It never touches real
        // chats, and a dismissal candidate costs one file read, once.
        Task { @MainActor [weak self] in
            while let self {
                self.autoDismissSweep()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    /// Whether the transcript on disk is too slight to list. The size
    /// gate keeps this a stat, not a parse, for any real conversation.
    nonisolated private static func isNegligibleOnDisk(_ ref: ChatSessionRef) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: ref.filePath)
        if let size = attrs?[.size] as? Int, size > 262_144 { return false }
        return ChatArchive.isNegligible(ChatArchive.transcript(ref))
    }

    /// Every quiet, unpinned session gets one substance check; the
    /// negligible ones are dismissed. `checkedFiles` keeps it one read
    /// per file per launch — a file that grows later gets re-indexed
    /// under a new mtime, and a dismissed file that grows is un-dismissed
    /// by the next sweep's re-check below.
    private var checkedFiles: Set<String> = []
    private func autoDismissSweep() {
        for (_, refs) in ChatIndexStore.shared.chats {
            for ref in refs {
                guard !checkedFiles.contains(ref.filePath),
                      Date().timeIntervalSince(ref.modified) > Self.dismissAfterQuiet,
                      !ChatMetaStore.shared.pinned.contains(ref.filePath),
                      activeChatFile != ref.filePath,
                      ChatSessionHub.shared.sessions[ref.filePath] == nil
                else { continue }
                checkedFiles.insert(ref.filePath)
                if Self.isNegligibleOnDisk(ref) {
                    dismiss(file: ref.filePath)
                }
            }
        }
        // A dismissed chat that grew back into a conversation (resumed
        // from the terminal, say) returns to the list.
        for file in dismissedFiles {
            guard let refs = ChatIndexStore.shared.chats.values
                .first(where: { $0.contains { $0.filePath == file } }),
                  let ref = refs.first(where: { $0.filePath == file }),
                  Date().timeIntervalSince(ref.modified) < Self.dismissAfterQuiet
            else { continue }
            if !Self.isNegligibleOnDisk(ref) {
                dismissedFiles.remove(file)
                checkedFiles.remove(file)
                scheduleSave()
            }
        }
    }

    func capsules(for project: String) -> [ChatCapsule] {
        capsules
            .filter { $0.project == project }
            .sorted { $0.sealedAt > $1.sealedAt }
    }

    func capsule(forFile file: String) -> ChatCapsule? {
        capsules.first { $0.sourceFile == file }
    }

    /// Legacy: whether a capsule exists for this file. The sidebar no
    /// longer filters on it — chats stay listed forever; only
    /// `isDismissed` hides anything.
    func isSealed(_ file: String) -> Bool {
        sealedFiles.contains(file)
    }

    /// Sessions too slight to list — the sidebar's only hide filter.
    func isDismissed(_ file: String) -> Bool {
        dismissedFiles.contains(file)
    }

    /// Hide a trivial chat without minting a capsule. Reversed only by
    /// deleting the transcript (`forget`) — there is nothing in these
    /// worth surfacing again.
    func dismiss(file: String) {
        guard !dismissedFiles.contains(file) else { return }
        dismissedFiles.insert(file)
        scheduleSave()
    }

    func seal(ref: ChatSessionRef, project: String, title: String) {
        guard !isSealed(ref.filePath) else { return }
        capsules.append(ChatCapsule(
            id: UUID().uuidString, project: project, sourceFile: ref.filePath,
            harness: ref.harness.rawValue, title: title, sealedAt: Date()
        ))
        sealedFiles.insert(ref.filePath)
        scheduleSave()
    }

    /// Reopen: the capsule dissolves and the chat returns to the open
    /// list — the transcript was never touched, so there is nothing to
    /// restore.
    func unseal(_ capsule: ChatCapsule) {
        capsules.removeAll { $0.id == capsule.id }
        sealedFiles.remove(capsule.sourceFile)
        scheduleSave()
    }

    /// A deleted transcript takes its capsule (or dismissal) with it.
    func forget(file: String) {
        guard sealedFiles.contains(file) || dismissedFiles.contains(file)
        else { return }
        capsules.removeAll { $0.sourceFile == file }
        sealedFiles.remove(file)
        dismissedFiles.remove(file)
        scheduleSave()
    }

    /// Coalesced — the auto-seal sweep can seal a whole backlog in one
    /// pass, and each seal must not re-encode the file.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            saveScheduled = false
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(capsules) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(dismissedFiles) {
            try? data.write(to: Self.dismissedURL, options: .atomic)
        }
    }
}
