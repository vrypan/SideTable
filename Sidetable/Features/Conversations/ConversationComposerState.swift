import Foundation
import Observation
import ApronCore

/// Transient composer state for one conversation view. Drafts and staged files
/// remain in AppModel and ServerModel so hiding the composer never discards them.
@MainActor @Observable
final class ConversationComposerState {
    struct EditingMessage: Identifiable {
        let id = UUID()
        let message: JSONObject
        let previews: [JSONObject]
        let account: String
    }

    private(set) var editingMessage: EditingMessage?
    private(set) var restoreFocus = false
    var focusRequest: UUID?
    var insertion: ComposerInsertion?
    var showingEmoji = false
    var showFilePicker = false
    var dropTargeted = false
    let linkLoader: ComposerLinkPreviewLoader
    private(set) var preparingSend = false
    @ObservationIgnored var sendTask: Task<Void, Never>?

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview")) {
        linkLoader = ComposerLinkPreviewLoader(preview: preview)
    }

    func beginEditing(_ message: JSONObject, previews: [JSONObject], account: String) {
        editingMessage = EditingMessage(message: message, previews: previews, account: account)
    }

    func finishEditing(_ id: UUID) {
        guard editingMessage?.id == id else { return }
        editingMessage = nil
        restoreFocus = true
    }

    func cancelEditing() { editingMessage = nil }

    /// Capture identity synchronously, before an item provider can suspend or
    /// the user can switch accounts. Stale results and errors are discarded.
    @discardableResult
    func stageDrop(server: ServerModel, room: String, category: String,
                   load: @escaping @MainActor () async throws -> [StagedFile]) -> Task<Void, Never> {
        let account = server.account, session = server.session
        return Task {
            do {
                let files = try await load()
                guard !Task.isCancelled, server.account == account, server.session === session else { return }
                try UploadMediaPolicy.validate(files, snapshot: server.snapshot, category: category)
                if !files.isEmpty { server.files[room, default: []].append(contentsOf: files) }
            } catch {
                guard !Task.isCancelled, server.account == account, server.session === session else { return }
                server.error = error.localizedDescription
            }
        }
    }

    func changeRoom() {
        sendTask?.cancel()
        cancelEditing()
        restoreFocus = false
        focusRequest = nil
    }

    func send(model: AppModel, server: ServerModel, room: String,
              fetch: @escaping @Sendable (URL) async -> JSONObject = { await ComposerOpenGraph.fetch($0) }) async -> Bool {
        guard !preparingSend, !model.preview, server.snapshot.phase == .ready else { return false }
        preparingSend = true
        defer { preparingSend = false }
        let draft = model.draft(server, room: room)
        let account = server.account, session = server.session
        let files = (server.files[room] ?? []).map(\.id)
        let request = linkRequest(draft: draft, key: DraftKey(server: server.id, account: account, room: room),
                                  commands: server.snapshot.supports("command"))
        let metadata = await linkLoader.metadataForSending(request, fetch: fetch)
        guard !Task.isCancelled, server.account == account, server.session === session,
              model.draft(server, room: room) == draft, (server.files[room] ?? []).map(\.id) == files else { return false }
        return model.send(server: server, room: room, linkMetadata: metadata)
    }

    func linkRequest(draft: SavedDraft, key: DraftKey, commands: Bool) -> ComposerLinkPreviewLoader.Request {
        let composed = ComposedText(draft.text, commands: commands)
        let links = composed.isCommand ? [] : ComposerLinkDiscovery.shared.links(in: composed.text)
            .filter { !draft.excludedPreviewURLs.contains($0.id) }
        return ComposerLinkPreviewLoader.Request(key: key, links: links)
    }
}
