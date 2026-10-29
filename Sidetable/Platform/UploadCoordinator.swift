import Foundation
import Observation
import ApronCore
import UniformTypeIdentifiers

// Keep the sandbox lease for as long as a staged/failed file can be retried.
final class StagedFile: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let scoped: Bool
    private let temporaryDirectory: URL?
    var name: String { url.lastPathComponent }
    init(url: URL, temporaryDirectory: URL? = nil) {
        self.url = url; self.temporaryDirectory = temporaryDirectory
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

enum UploadPhase: String {
    case waiting = "Waiting", uploading = "Uploading", confirming = "Waiting for server confirmation"
    case complete = "Complete", failed = "Failed", cancelled = "Cancelled"
}

@MainActor @Observable final class PendingUpload: Identifiable {
    let id = UUID()
    let name: String
    var file: StagedFile?
    var phase: UploadPhase = .waiting
    var bytes: Int64 = 0
    var total: Int64?
    var error: String?
    var embedID: String?
    // Ephemeral credential. Never include in errors, logs, or persistence.
    @ObservationIgnored var writeURL: URL?
    @ObservationIgnored var attempted = false
    @ObservationIgnored var generation = UUID()
    var canRetry: Bool { !attempted && writeURL != nil && file != nil && [.failed, .cancelled].contains(phase) }
    init(_ file: StagedFile) { self.file = file; name = file.name }
}

@MainActor @Observable final class PendingMessage: Identifiable {
    let id: String
    let room: String
    let account: String
    let params: JSONObject
    let text: String
    let isCommand: Bool
    let hiddenPreviewURLs: Set<String>
    var error: String?
    var sending = false
    var acknowledged = false
    var messageID: String?
    var uploads: [PendingUpload]
    @ObservationIgnored var generation = UUID()
    init(id: String, room: String, account: String, params: JSONObject, text: String,
         files: [StagedFile] = [], isCommand: Bool = false, hiddenPreviewURLs: Set<String> = []) {
        self.id = id; self.room = room; self.account = account; self.params = params
        self.text = text; self.isCommand = isCommand; uploads = files.map(PendingUpload.init)
        self.hiddenPreviewURLs = hiddenPreviewURLs
    }
}

struct UploadFailure: Error {
    let message: String
    let mayHaveConsumedURL: Bool
}

typealias UploadProgress = @Sendable (Int64, Int64?) -> Void

struct FileUploader: Sendable {
    var transfer: @Sendable (URL, URL, URL, @escaping UploadProgress) async throws -> Void
    static let live = configured { .ephemeral }
    static func configured(_ configuration: @escaping @Sendable () -> URLSessionConfiguration) -> FileUploader {
        FileUploader { file, destination, endpoint, progress in
            guard MediaPolicy.allows(destination, endpoint: endpoint) else {
                throw UploadFailure(message: "This upload destination is not trusted. Reattach the file after checking the server.", mayHaveConsumedURL: false)
            }
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw UploadFailure(message: "The local file is unavailable. Select it again to attach it.", mayHaveConsumedURL: false)
            }
            let delegate = UploadDelegate(progress: progress)
            let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: destination)
            request.httpMethod = "PUT"; request.timeoutInterval = 120
            request.setValue(UploadMediaPolicy.contentType(file), forHTTPHeaderField: "Content-Type")
            do {
                let (_, response) = try await session.upload(for: request, fromFile: file)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    throw UploadFailure(message: "The server rejected the upload. Its single-use link may have expired; reattach the file.", mayHaveConsumedURL: true)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let failure as UploadFailure { throw failure }
            catch {
                // URLSession errors can contain the credential-bearing URL.
                throw UploadFailure(message: "The transfer was interrupted. Check whether the attachment arrived before reattaching it.", mayHaveConsumedURL: true)
            }
        }
    }
}

private final class UploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: UploadProgress
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(progress: @escaping UploadProgress) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let now = Date()
        let report = now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesSent == totalBytesExpectedToSend
        if report { lastUpdate = now }
        lock.unlock()
        if report { progress(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable final class UploadCoordinator {
    typealias Submit = @MainActor (String, JSONObject, String) async throws -> JSONObject
    var messages: [PendingMessage] = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let uploader: FileUploader
    @ObservationIgnored private var latestStore: RecordStore?
    init(uploader: FileUploader = .live) { self.uploader = uploader }
    var hasUnfinishedFiles: Bool {
        messages.contains { $0.uploads.contains { $0.phase != .complete && ($0.file != nil || [.waiting, .uploading, .confirming].contains($0.phase)) } }
    }

    func submit(_ message: PendingMessage, endpoint: URL, using perform: @escaping Submit) {
        guard messages.contains(where: { $0 === message }), !message.sending, !message.acknowledged else { return }
        message.sending = true; message.error = nil
        let epoch = UUID(); message.generation = epoch
        tasks[message.id] = Task {
            defer { if message.generation == epoch { tasks[message.id] = nil } }
            do {
                let result = try await perform(message.isCommand ? "command" : "message", message.params, message.id)
                guard message.generation == epoch, !Task.isCancelled else { return }
                message.sending = false; message.acknowledged = true; message.messageID = result.string("message_id")
                if message.uploads.isEmpty { messages.removeAll { $0 === message }; return }
                guard message.isCommand || message.messageID != nil else {
                    for upload in message.uploads { upload.phase = .failed; upload.error = "The server did not identify the message. Check the conversation before reattaching files." }
                    return
                }
                let descriptors = result.objects("embeds")
                let ids = descriptors.compactMap { $0.string("embed_id") }
                guard descriptors.count == message.uploads.count, ids.count == descriptors.count, Set(ids).count == ids.count else {
                    for upload in message.uploads { upload.phase = .failed; upload.error = "The server returned incomplete attachment details. Reattach the file." }
                    return
                }
                for (upload, descriptor) in zip(message.uploads, descriptors) {
                    upload.embedID = descriptor.string("embed_id")
                    guard descriptor.string("kind") == "upload", let address = descriptor.string("write_url"), let url = URL(string: address) else {
                        upload.phase = .failed; upload.error = "The server did not provide an upload link. Reattach the file."; continue
                    }
                    upload.writeURL = url
                    start(upload, message: message, endpoint: endpoint)
                }
                if let latestStore { reconcile(latestStore) }
            } catch {
                guard message.generation == epoch, !Task.isCancelled else { return }
                message.sending = false
                // A command is never logged, so its error is definitive: show the
                // server's own message (§4.1) rather than uncertain delivery.
                if let rejection = error as? RPCError, rejection.retryAfter != nil {
                    message.error = "The server asked you to wait before retrying."
                }
                else if message.isCommand, let rejection = error as? RPCError { message.error = rejection.message }
                else { message.error = "Delivery is uncertain. Retry the same operation to check without creating a second message." }
            }
        }
    }

    func start(_ upload: PendingUpload, message: PendingMessage, endpoint: URL) {
        guard messages.contains(where: { $0 === message }), message.acknowledged,
              upload.phase == .waiting || upload.canRetry, let file = upload.file, let url = upload.writeURL else { return }
        upload.phase = .uploading; upload.error = nil; upload.bytes = 0; upload.attempted = true
        let epoch = UUID(); upload.generation = epoch
        let key = upload.id.uuidString
        tasks[key] = Task { [self, upload] in
            defer { if upload.generation == epoch { tasks[key] = nil } }
            do {
                try await uploader.transfer(file.url, url, endpoint) { [weak upload] bytes, total in
                    Task { @MainActor in
                        guard let upload, upload.generation == epoch, upload.phase == .uploading else { return }
                        upload.bytes = max(upload.bytes, bytes); upload.total = total
                    }
                }
                guard upload.generation == epoch, !Task.isCancelled, upload.phase == .uploading else { return }
                upload.phase = message.isCommand ? .complete : .confirming
                upload.writeURL = nil
                if message.isCommand { upload.file = nil }
            } catch {
                guard upload.generation == epoch, !Task.isCancelled, upload.phase == .uploading else { return }
                upload.phase = .failed
                if let failure = error as? UploadFailure {
                    upload.error = failure.message; upload.attempted = failure.mayHaveConsumedURL
                } else { upload.error = "Transfer interrupted. Check the attachment before reattaching it." }
                if upload.attempted || !MediaPolicy.allows(url, endpoint: endpoint) { upload.writeURL = nil }
            }
        }
    }

    func cancel(_ upload: PendingUpload) {
        guard [.waiting, .uploading].contains(upload.phase) else { return }
        upload.generation = UUID(); tasks.removeValue(forKey: upload.id.uuidString)?.cancel()
        upload.phase = .cancelled
        upload.error = "Transfer cancelled locally. The message remains on the server."
        if upload.attempted { upload.writeURL = nil }
    }
    func dismiss(_ message: PendingMessage) {
        message.generation = UUID(); tasks.removeValue(forKey: message.id)?.cancel()
        for upload in message.uploads {
            upload.generation = UUID(); tasks.removeValue(forKey: upload.id.uuidString)?.cancel()
            upload.file = nil; upload.writeURL = nil
        }
        messages.removeAll { $0 === message }
    }
    func reset() { for message in messages { dismiss(message) }; latestStore = nil }

    func reconcile(_ store: RecordStore) {
        latestStore = store
        for delivery in messages where delivery.acknowledged {
            guard let id = delivery.messageID, let message = store.messages[id] else { continue }
            let embeds = message.object("body").objects("embeds")
            for upload in delivery.uploads {
                guard upload.phase != .complete, let embedID = upload.embedID else { continue }
                if let embed = embeds.first(where: { $0.string("embed_id") == embedID }) {
                    if embed.string("url") != nil {
                        upload.generation = UUID(); tasks.removeValue(forKey: upload.id.uuidString)?.cancel()
                        upload.phase = .complete; upload.file = nil; upload.writeURL = nil; upload.error = nil
                    }
                } else if message.bool("deleted") || (message.logID("log_id") ?? 0) > (UInt64(id) ?? 0) {
                    upload.generation = UUID(); tasks.removeValue(forKey: upload.id.uuidString)?.cancel()
                    upload.phase = .failed; upload.writeURL = nil
                    upload.error = "The server removed this attachment. Reattach it if it is still needed."
                }
            }
        }
    }
}

/// Use the same MIME type for policy checks and the actual write.
enum UploadMediaPolicy {
    static func contentType(_ file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    static func problem(type: String, bytes: Int, rules: JSONObject?) -> String? {
        guard let rules else { return nil }
        let type = type.lowercased()
        let patterns = [type, String(type.split(separator: "/").first ?? "") + "/*", "*/*"]
        let normalized = rules.sorted { $0.key < $1.key }.reduce(into: JSONObject()) { $0[$1.key.lowercased()] = $1.value }
        guard let limits = patterns.compactMap({ normalized[$0]?.object }).first else {
            return "This server does not accept files of type \(type)."
        }
        if let maximum = limits["max_bytes"]?.number, maximum.isFinite, maximum >= 0, Double(bytes) > maximum {
            return "This file exceeds the server’s upload size limit."
        }
        return nil
    }
    static func validate(_ files: [StagedFile], snapshot: SessionSnapshot, category: String = "upload") throws {
        guard snapshot.supports("ext:media") else { return }
        let rules = snapshot.server.object("ext").object("media")[category]?.object
        for file in files {
            let bytes = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if let problem = problem(type: contentType(file.url), bytes: bytes, rules: rules) {
                throw UploadFailure(message: problem, mayHaveConsumedURL: false)
            }
        }
    }
}
