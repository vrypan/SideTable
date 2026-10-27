import Foundation
import CryptoKit

extension Notification.Name {
    static let mediaCacheCleared = Notification.Name("SideTableMediaCacheCleared")
}

/// Downloaded attachment bytes, isolated by server and account. URL policy is checked by the caller
/// even on cache hits. Concurrent views share a transfer; failed transfers never become cache entries.
actor MediaCache {
    static let shared = MediaCache()
    static let maximumDownloadBytes = 64 * 1024 * 1024
    static let defaultCapacity = 256 * 1024 * 1024
    typealias Downloader = @Sendable (URL, Int) async throws -> Data
    private let directory: URL
    private let capacity: Int
    private let downloader: Downloader
    private struct Pending {
        let id: UUID
        let server: UUID
        let task: Task<Data, Error>
    }
    private var pending: [String: Pending] = [:]
    private var previews: [URL: (server: UUID, size: Int)] = [:]
    private var clearGeneration = UUID()

    init(directory: URL? = nil, capacity: Int = defaultCapacity, downloader: @escaping Downloader = MediaCache.download) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SideTable/Media", isDirectory: true)
        self.capacity = capacity
        self.downloader = downloader
        // No Quick Look leases survive a process launch. Remove leftovers from a
        // crash, and migrate the old unmanaged temporary preview directory.
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent("Previews"))
        if directory == nil {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("SidetablePreviews"))
        }
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func data(for url: URL, server: UUID, account: String, limit: Int, maxAge: TimeInterval? = nil) async throws -> Data {
        let file = directory.appendingPathComponent(server.uuidString)
            .appendingPathComponent(Self.digest(account)).appendingPathComponent(Self.digest(url.absoluteString))
        if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
           let size = values.fileSize, size <= Self.maximumDownloadBytes,
           maxAge.map({ Date().timeIntervalSince(values.creationDate ?? .distantPast) < $0 }) ?? true,
           let data = try? Data(contentsOf: file) {
            // The small preview limit bounds automatic network traffic, not an already downloaded file.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        let limit = min(limit, Self.maximumDownloadBytes)
        let key = file.path + ":\(limit)"
        if let transfer = pending[key] { return try await transfer.task.value }
        let id = UUID()
        let downloader = self.downloader
        let task = Task {
            let data = try await downloader(url, limit)
            try Task.checkCancellation()
            guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            return data
        }
        pending[key] = Pending(id: id, server: server, task: task)
        do {
            let data = try await task.value
            guard pending[key]?.id == id else { throw CancellationError() }
            pending[key] = nil
            // A full or unavailable cache must not prevent viewing a successfully downloaded file.
            if data.count <= capacity {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.creationDate: Date(), .modificationDate: Date()], ofItemAtPath: file.path)
                trim()
            }
            return data
        } catch {
            if pending[key]?.id == id { pending[key] = nil }
            throw error
        }
    }

    func usage() -> Int64 { files().reduce(0) { $0 + Int64($1.size) } }

    /// Quick Look needs a filename/extension. Its temporary copy participates in
    /// cache accounting and stays pinned until the view releases it.
    func previewFile(for url: URL, server: UUID, account: String, filename: String) async throws -> URL {
        let generation = clearGeneration
        let data = try await data(for: url, server: server, account: account, limit: Self.maximumDownloadBytes)
        try Task.checkCancellation()
        guard generation == clearGeneration else { throw CancellationError() }
        guard previews.values.reduce(0, { $0 + $1.size }) + data.count <= capacity else {
            throw URLError(.cannotCreateFile)
        }
        let name = (filename as NSString).lastPathComponent
        let safeName = ["", ".", "..", "/"].contains(name) ? "Attachment" : name
        let folder = directory.appendingPathComponent("Previews").appendingPathComponent(server.uuidString)
            .appendingPathComponent(Self.digest(account)).appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        previews[file] = (server, data.count)
        trim()
        return file
    }

    func releasePreview(_ file: URL) {
        guard previews.removeValue(forKey: file) != nil else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func clear(server: UUID? = nil) throws {
        clearGeneration = UUID()
        for (key, transfer) in pending where server == nil || transfer.server == server {
            transfer.task.cancel(); pending[key] = nil
        }
        let target = server.map { directory.appendingPathComponent($0.uuidString) } ?? directory
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        if let server {
            let previewRoot = directory.appendingPathComponent("Previews").appendingPathComponent(server.uuidString)
            if FileManager.default.fileExists(atPath: previewRoot.path) { try FileManager.default.removeItem(at: previewRoot) }
        }
        previews = previews.filter { server != nil && $0.value.server != server }
    }

    private func files() -> [(url: URL, size: Int, date: Date)] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() {
        let entries = files().sorted { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > capacity && previews[entry.url] == nil {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    nonisolated static func download(_ url: URL, limit: Int) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
