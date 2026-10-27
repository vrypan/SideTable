import Foundation
import LinkPresentation
import UniformTypeIdentifiers
import ApronCore

struct ComposerWebPreview: Sendable {
    var metadata: JSONObject = [:]
    var imageData: Data?
}

/// Only explicitly composed links use the system website fetcher. Received
/// messages continue to use server-provided media and the server origin policy.
@MainActor final class ComposerWebPreviewFetcher {
    private let provider = LPMetadataProvider()

    func load(_ url: URL) async -> ComposerWebPreview? {
        guard MediaPolicy.safeLink(url), url.host?.isEmpty == false, !Task.isCancelled else { return nil }
        provider.timeout = 10
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                provider.startFetchingMetadata(for: url) { metadata, _ in
                    guard let metadata else { continuation.resume(returning: nil); return }
                    var values: JSONObject = [:]
                    if let title = metadata.title, !title.isEmpty { values["title"] = .string(title) }
                    guard let image = metadata.imageProvider,
                          let type = image.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                        continuation.resume(returning: ComposerWebPreview(metadata: values)); return
                    }
                    let text = values
                    image.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        // The system owns the network request; bound the bytes we retain and decode.
                        let bounded = data.flatMap { $0.count <= 8 * 1024 * 1024 ? $0 : nil }
                        continuation.resume(returning: ComposerWebPreview(metadata: text, imageData: bounded))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.provider.cancel() }
        }
    }
}
