import Foundation
import Security
import Darwin

struct ServerProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var address: String
    var accountID: String?
    /// Accounts signed out of, most recent first. Their tokens stay in Keychain
    /// until the user continues as one, forgets it, or removes the server.
    /// Optional so profiles saved before this field still decode.
    var savedAccountIDs: [String]?
    var savedAccounts: [String] {
        get { savedAccountIDs ?? [] }
        set { savedAccountIDs = newValue.isEmpty ? nil : newValue }
    }
    var title: String { URL(string: address)?.host ?? "Server" }
}

struct DraftKey: Codable, Hashable {
    var server: UUID
    var account: String
    var room: String
}

struct SavedLocation: Codable, Equatable {
    var server: UUID
    var account: String
    var room: String
    var thread: String?
}

struct SavedPanelLayout: Codable, Equatable {
    struct Panel: Codable, Equatable {
        var id: UUID
        var server: UUID
        var account: String
        var room: String
        var isThread: Bool
        var width: Double?
    }
    var panels: [Panel]
    var activePanel: UUID?
    var selectedServer: UUID?
}

struct SavedMembersPanel: Codable, Equatable {
    var expanded: Bool
    var width: Double?
}

struct SavedDraft: Codable, Equatable {
    var text = ""
    var replyTo: String?
    var excludedPreviewURLs: Set<String> = []

    init(text: String = "", replyTo: String? = nil, excludedPreviewURLs: Set<String> = []) {
        self.text = text; self.replyTo = replyTo; self.excludedPreviewURLs = excludedPreviewURLs
    }
    private enum CodingKeys: String, CodingKey { case text, replyTo, excludedPreviewURLs }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        replyTo = try values.decodeIfPresent(String.self, forKey: .replyTo)
        excludedPreviewURLs = try values.decodeIfPresent(Set<String>.self, forKey: .excludedPreviewURLs) ?? []
    }
}

@MainActor
final class LocalStorage {
    private let directory: URL
    private let cacheWriter: ConversationCacheWriter
    init(directory: URL? = nil, cacheWriter: ConversationCacheWriter = ConversationCacheWriter()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sidetable", isDirectory: true)
        self.cacheWriter = cacheWriter
    }
    func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    func prepareConversationCache(_ value: CachedView, server: UUID) async throws -> PreparedConversationCache {
        try await cacheWriter.prepare(value, destination: directory.appendingPathComponent("cache-\(server).json"))
    }
    func conversationCacheUsage() throws -> [UUID: Int64] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var usage: [UUID: Int64] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("cache-"), name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropFirst(6).dropLast(5))) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            usage[id] = Int64(values.fileSize ?? 0)
        }
        return usage
    }
    func removeConversationCache(_ server: UUID) throws {
        let file = directory.appendingPathComponent("cache-\(server).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

}

/// Encoding and writing the file contents never occupy the main actor. The caller
/// validates its account/generation before the small, synchronous atomic rename.
actor ConversationCacheWriter {
    private let beforeWrite: @Sendable () async -> Void
    private(set) var writeCount = 0
    init(beforeWrite: @escaping @Sendable () async -> Void = {}) { self.beforeWrite = beforeWrite }
    func prepare(_ value: CachedView, destination: URL) async throws -> PreparedConversationCache {
        await beforeWrite()
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(value)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let prepared = PreparedConversationCache(directory: temporary, destination: destination)
        do {
            try data.write(to: prepared.file)
            try Task.checkCancellation()
            writeCount += 1
            return prepared
        } catch { prepared.discard(); throw error }
    }
}

struct PreparedConversationCache: Sendable {
    let directory: URL
    let destination: URL
    var file: URL { directory.appendingPathComponent("conversation.json") }
    func commit() throws {
        guard rename(file.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    func discard() { try? FileManager.default.removeItem(at: directory) }
}

enum AppRuntime {
    static var isTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SIDETABLE_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

@MainActor
protocol CredentialStore {
    func read(endpoint: String, account: String) -> String?
    func save(_ token: String, endpoint: String, account: String) throws
    func delete(endpoint: String, account: String) throws
}

@MainActor
final class MemoryCredentialStore: CredentialStore {
    private struct Key: Hashable { let endpoint: String; let account: String }
    private var tokens: [Key: String] = [:]
    func read(endpoint: String, account: String) -> String? { tokens[Key(endpoint: endpoint, account: account)] }
    func save(_ token: String, endpoint: String, account: String) {
        tokens[Key(endpoint: endpoint, account: account)] = token
    }
    func delete(endpoint: String, account: String) { tokens[Key(endpoint: endpoint, account: account)] = nil }
}

@MainActor
struct KeychainCredentialStore: CredentialStore {
    func read(endpoint: String, account: String) -> String? { CredentialVault.read(endpoint: endpoint, account: account) }
    func save(_ token: String, endpoint: String, account: String) throws { try CredentialVault.save(token, endpoint: endpoint, account: account) }
    func delete(endpoint: String, account: String) throws { try CredentialVault.delete(endpoint: endpoint, account: account) }
}

private enum CredentialVault {
    static func read(endpoint: String, account: String) -> String? {
        var query = base(endpoint, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, endpoint: String, account: String) throws {
        let query = base(endpoint, account)
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete(endpoint: String, account: String) throws {
        let status = SecItemDelete(base(endpoint, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func base(_ endpoint: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "chat.sidetable.mac:" + endpoint, kSecAttrAccount as String: account]
    }
}
