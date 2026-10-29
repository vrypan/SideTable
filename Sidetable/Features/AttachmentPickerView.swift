import ApronCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentPickerView: View {
    let snapshot: SessionSnapshot
    var category = "upload"
    var multiple = true
    let selected: ([StagedFile]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Attachments").font(.title2.weight(.semibold))
            Text("Accepted files").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(UploadMediaPolicy.guidance(snapshot: snapshot, category: category), id: \.self) {
                        Text(userText: $0).font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            if let error { Text(userText: error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Files…") { choosing = true }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 460)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: multiple) { result in
                do {
                    let files = try result.get().map { StagedFile(url: $0) }
                    try UploadMediaPolicy.validate(files, snapshot: snapshot, category: category)
                    selected(files); dismiss()
                } catch { self.error = error.localizedDescription }
            }
    }
}
