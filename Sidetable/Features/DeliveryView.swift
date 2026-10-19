import SwiftUI
import AppKit

struct DeliveryView: View {
    @Bindable var model: AppModel
    @Bindable var server: ServerModel
    @Bindable var message: PendingMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.acknowledged { Text(message.text).foregroundStyle(.secondary).textSelection(.enabled) }
            if message.sending { Label("Sending…", systemImage: "clock").font(.caption) }
            if let error = message.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("Copy Text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                Button("Retry Same Operation") { model.retry(message, server: server) }
                    .disabled(message.sending || server.snapshot.phase != .ready || server.snapshot.readOnly)
            }
            ForEach(message.uploads) { upload in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: upload.phase == .complete ? "checkmark.circle" : "doc")
                        Text(upload.name).lineLimit(1)
                        Spacer()
                        Text(upload.phase.rawValue).foregroundStyle(.secondary)
                    }
                    if upload.phase == .uploading {
                        if let total = upload.total {
                            ProgressView(value: Double(min(upload.bytes, total)), total: Double(max(1, total)))
                                .accessibilityLabel("Uploading \(upload.name)")
                            Text("\(ByteCountFormatter.string(fromByteCount: upload.bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))").foregroundStyle(.secondary)
                        } else { ProgressView().controlSize(.small).accessibilityLabel("Uploading \(upload.name)") }
                    }
                    if let error = upload.error { Text(error).foregroundStyle(.secondary) }
                    HStack {
                        if [.waiting, .uploading].contains(upload.phase), message.acknowledged {
                            Button("Cancel") { server.uploads.cancel(upload) }.accessibilityLabel("Cancel upload of \(upload.name)")
                        }
                        if upload.canRetry {
                            Button("Retry Upload") {
                                if let endpoint = URL(string: server.profile.address) { server.uploads.start(upload, message: message, endpoint: endpoint) }
                            }.disabled(server.snapshot.readOnly || server.snapshot.phase != .ready)
                        }
                        if [.failed, .cancelled].contains(upload.phase), upload.file != nil {
                            Button("Reattach to Composer") { model.reattach(upload, message: message, server: server) }
                                .disabled(server.snapshot.readOnly || !server.snapshot.supports("embed:upload"))
                        }
                    }
                }.font(.caption).padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            }
            if !message.sending && (!message.acknowledged || !message.uploads.contains(where: { [.uploading, .waiting].contains($0.phase) })) {
                Button(message.uploads.allSatisfy { $0.phase == .complete } && message.acknowledged ? "Done" : "Dismiss") { server.uploads.dismiss(message) }.font(.caption)
            }
        }
    }
}
