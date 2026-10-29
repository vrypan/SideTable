import SwiftUI
import ApronCore

struct MessageEditorView: View {
    let knownUserIDs: Set<String>
    let protocolVersion: Double
    let referenceNames: [String: String]
    let contextID: String
    let save: @MainActor (MessageEdit, JSONObject) async throws -> Void
    @State private var draft: MessageEdit
    @State private var saving = false
    @State private var error: String?
    @State private var removal: Int?
    @Environment(\.dismiss) private var dismiss

    init(message: JSONObject, localPreviews: [JSONObject] = [], knownUserIDs: Set<String>, protocolVersion: Double = 9, referenceNames: [String: String] = [:], contextID: String,
         save: @escaping @MainActor (MessageEdit, JSONObject) async throws -> Void) {
        self.knownUserIDs = knownUserIDs; self.protocolVersion = protocolVersion
        self.referenceNames = referenceNames
        self.contextID = contextID; self.save = save
        _draft = State(initialValue: MessageEdit(message: message, localPreviews: localPreviews))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit message").font(.title2.weight(.semibold))
            NativeComposer(text: $draft.text, placeholder: "Message text", enabled: !saving,
                candidates: referenceNames.sorted { $0.key < $1.key }.map {
                    ComposerSuggestion(insertion: $0.key, label: $0.value + " · " + $0.key, search: $0.value + " " + $0.key)
                }, referenceNames: referenceNames, markdown: draft.original.object("body").string("format") == "markdown",
                returnSends: false, contextID: contextID, send: {})
                .frame(height: 150).border(.quaternary).accessibilityLabel("Message text")
            if !draft.attachments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.attachments.indices, id: \.self) { index in
                            attachmentRow(index)
                        }
                    }
                }.frame(maxHeight: 220)
            }
            if let error { Text(userText: error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !draft.canSave {
                Text("Keep some text or an attachment, and give each file a name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save Changes") { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || !draft.canSave)
            }
        }.padding(24).frame(width: 480)
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .onChange(of: contextID) { dismiss() }
            .confirmationDialog("Remove this attachment?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button("Remove Attachment", role: .destructive) {
                    if let removal { draft.remove(removal) }
                    removal = nil
                }
                Button("Cancel", role: .cancel) { removal = nil }
            } message: {
                Text("Saving these changes will ask the server to delete the uploaded file or stream content. Cancel the edit to keep it.")
            }
    }

    @ViewBuilder private func attachmentRow(_ index: Int) -> some View {
        let attachment = draft.attachments[index]
        HStack(spacing: 10) {
            Image(systemName: attachment.original.string("kind") == "link" ? "link" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                if attachment.canRename && !attachment.removed {
                    TextField("Filename", text: $draft.attachments[index].title)
                        .accessibilityLabel("Attachment filename")
                } else {
                    Text(userText: attachment.title).lineLimit(2).truncationMode(.middle)
                }
                Text(userText: attachment.localOnly ? (attachment.removed ? "Hidden on this Mac when saved" : "Preview on this Mac") : attachment.removed ? "Removed when saved" : attachment.pending ? "Upload pending…" : attachment.original.string("kind")?.capitalized ?? "Attachment")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if attachment.removed {
                Button("Undo") { draft.restore(attachment.id) }
            } else if attachment.canRemove {
                Button {
                    if attachment.removesContent { removal = attachment.id }
                    else { draft.remove(attachment.id) }
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Remove attachment")
                    .accessibilityLabel("Remove \(attachment.title)")
            }
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func submit() {
        guard !saving, draft.canSave else { return }
        guard draft.changed else { dismiss(); return }
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                let params = try draft.parameters(knownUserIDs: knownUserIDs, protocolVersion: protocolVersion)
                try await save(draft, params)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
