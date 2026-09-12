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
    /// Stage a capsule as a composer attachment chip (`object` is the
    /// `ChatCapsule`).
    static let houstonComposerAttachCapsule = Notification.Name("houstonComposerAttachCapsule")
    /// Open a capsule's transcript in the right sheet (`object` is the
    /// capsule's source-file path) — posted by chips in chat transcripts.
    static let houstonOpenCapsule = Notification.Name("houstonOpenCapsule")
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
    private var saveScheduled = false

    /// Fallback inactivity horizon for the *current* chat: a project's
    /// newest chat seals only once it's been quiet this long AND a newer
    /// chat exists — see `autoSealSweep`.
    static let idleSealAfter: TimeInterval = 30 * 60

    private static var fileURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("capsules.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([ChatCapsule].self, from: data) {
            capsules = stored
            sealedFiles = Set(stored.map(\.sourceFile))
        }
        // The auto-seal heartbeat. The sweep is an in-memory timestamp
        // compare over the cached chat index — no file reads, no model
        // calls — so a 2-minute cadence costs nothing.
        Task { @MainActor [weak self] in
            while let self {
                self.autoSealSweep()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    /// One active chat per project: the newest chat stays open until a
    /// newer one exists — every other chat seals into a capsule (unless
    /// it's pinned, archived, on screen, or its agent is mid-turn).
    private func autoSealSweep() {
        for (project, refs) in ChatIndexStore.shared.chats {
            let newest = refs.max { $0.modified < $1.modified }?.filePath
            for ref in refs where ref.filePath != newest {
                guard !isSealed(ref.filePath),
                      !ChatMetaStore.shared.pinned.contains(ref.filePath),
                      !ChatMetaStore.shared.archived.contains(ref.filePath),
                      activeChatFile != ref.filePath,
                      ChatSessionHub.shared.sessions[ref.filePath] == nil
                else { continue }
                seal(
                    ref: ref, project: project,
                    title: ChatTitler.shared.displayTitle(ref)
                )
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

    /// Sealed chats leave the sidebar's open list — this is the filter.
    func isSealed(_ file: String) -> Bool {
        sealedFiles.contains(file)
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

    /// A deleted transcript takes its capsule with it.
    func forget(file: String) {
        guard sealedFiles.contains(file) else { return }
        capsules.removeAll { $0.sourceFile == file }
        sealedFiles.remove(file)
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
        guard let data = try? JSONEncoder().encode(capsules) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
