import Foundation
import AppKit
import SwiftUI
import Testing
import ApronCore
@testable import Sidetable

@Test func builtAppContainsNumericAndDisplayVersions() throws {
    let info = try #require(Bundle.main.infoDictionary)
    let release = try #require(info["CFBundleShortVersionString"] as? String)
    let build = try #require(info["CFBundleVersion"] as? String)
    let display = try #require(info["SideTableVersion"] as? String)
    #expect(release.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil)
    #expect(build == release)
    #expect(display == release || display.hasPrefix(release + "-"))
}

@MainActor @Test func draftsPreserveAccountAndEndpointIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalStorage(directory: root)
    let server = UUID()
    let a = DraftKey(server: server, account: "ada", room: "general")
    let b = DraftKey(server: server, account: "ben", room: "general")
    let drafts = [a: SavedDraft(text: "Private draft", replyTo: "100"), b: SavedDraft(text: "Different user")]
    try store.write(drafts, to: "drafts.json")
    #expect(store.read("drafts.json", as: [DraftKey: SavedDraft].self) == drafts)
}

@Test func mediaRequestsCannotCrossOrigins() {
    let server = URL(string: "wss://chat.example/ws")!
    #expect(MediaPolicy.allows(URL(string: "https://chat.example/files/a")!, endpoint: server))
    #expect(!MediaPolicy.allows(URL(string: "https://evil.example/files/a")!, endpoint: server))
    #expect(!MediaPolicy.allows(URL(string: "https://chat.example:444/files/a")!, endpoint: server))
    #expect(!MediaPolicy.safeLink(URL(string: "javascript:alert(1)")!))
}

@MainActor @Test func locationRestoresSelectedServerRoomAndDeferredThread() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let first = ServerProfile(address: "wss://first.example/", accountID: "ada")
    let second = ServerProfile(address: "wss://second.example/", accountID: "ben")
    let saved = SavedLocation(server: second.id, account: "ben", room: "general", thread: "discussion")
    try storage.write([first, second], to: "servers-v1.json")
    try storage.write(saved, to: "location-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    #expect(model.selectedServer == second.id)
    let server = try #require(model.current)
    model.saveLocation() // Startup must not overwrite the pending destination.
    #expect(storage.read("location-v1.json", as: SavedLocation.self) == saved)
    server.snapshot.phase = .ready
    server.snapshot.you = ["user_id": .string("ben")]
    server.snapshot.store.joined = ["general"]
    server.snapshot.store.installRoom(["room_id": .string("general")])
    model.restoreLocation(server: server)
    #expect(server.selectedRoom == "general")
    #expect(model.thread == nil) // Public thread absent from initial joined-room listing.
    model.saveLocation()
    #expect(storage.read("location-v1.json", as: SavedLocation.self) == saved)
    server.snapshot.store.installRoom(["room_id": .string("discussion"), "parent_room_id": .string("general")])
    model.restoreLocation(server: server, finishedListing: true)
    #expect(model.thread == "discussion")
    model.thread = nil
    #expect(storage.read("location-v1.json", as: SavedLocation.self)?.thread == nil)
    model.selectRoom("discussion", server: server, asThread: true)
    #expect(storage.read("location-v1.json", as: SavedLocation.self) == saved)
    let reopened = AppModel(storage: storage, connectOnLaunch: false)
    #expect(reopened.selectedServer == second.id)
}

@MainActor @Test func locationRejectsDifferentAccountsAndUnavailableThreads() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    let saved = SavedLocation(server: profile.id, account: "ada", room: "general", thread: "removed")
    for account in ["ada", "different-user"] {
        try storage.write(saved, to: "location-v1.json")
        let model = AppModel(storage: storage, connectOnLaunch: false)
        let server = try #require(model.current)
        server.snapshot.phase = .ready
        server.snapshot.you = ["user_id": .string(account)]
        server.snapshot.store.joined = ["general"]
        server.snapshot.store.installRoom(["room_id": .string("general")])
        server.selectedRoom = "general"
        model.restoreLocation(server: server, finishedListing: true)
        #expect(model.thread == nil)
        #expect(storage.read("location-v1.json", as: SavedLocation.self)?.account == account)
        #expect(storage.read("location-v1.json", as: SavedLocation.self)?.thread == nil)
    }
}

@MainActor @Test func manualNavigationSupersedesPendingRestoration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let profile = ServerProfile(address: "wss://chat.example/", accountID: "ada")
    try storage.write([profile], to: "servers-v1.json")
    try storage.write(SavedLocation(server: profile.id, account: "ada", room: "old", thread: "old-thread"), to: "location-v1.json")
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = try #require(model.current)
    model.selectRoom("chosen", server: server)
    server.snapshot.phase = .ready
    model.restoreLocation(server: server, finishedListing: true)
    #expect(server.selectedRoom == "chosen")
    #expect(model.thread == nil)
    #expect(storage.read("location-v1.json", as: SavedLocation.self)?.room == "chosen")
}

@Test func attachmentMediaAcceptsOnlyDeclaredOrigins() {
    let server = URL(string: "wss://chat.example/ws")!
    let media = URL(string: "https://cdn.example/files/a.png")!
    #expect(MediaPolicy.allows(media, endpoint: server, mediaOrigins: ["https://cdn.example"]))
    for origin in ["https://cdn.example/path", "https://cdn.example?query", "https://cdn.example#fragment", "http://cdn.example", "https://user@cdn.example", "https://cdn.example:444"] {
        #expect(!MediaPolicy.allows(media, endpoint: server, mediaOrigins: [origin]))
    }
    for address in ["https://cdn.example.evil/a", "http://cdn.example/a", "https://user@cdn.example/a", "https://cdn.example:444/a"] {
        #expect(!MediaPolicy.allows(URL(string: address)!, endpoint: server, mediaOrigins: ["https://cdn.example"]))
    }
    #expect(MediaPolicy.allows(URL(string: "http://localhost:8080/a")!, endpoint: server, mediaOrigins: ["http://localhost:8080"]))
}

@Test func attachmentPresentationDistinguishesImagesFilesAndPosters() {
    let address = "https://chat.example/file"
    var embed: JSONObject = ["kind": .string("upload"), "title": .string("photo.png"), "url": .string(address)]
    #expect(AttachmentPresentation(embed: embed).imageURL?.absoluteString == address)
    embed["title"] = .string("report.pdf")
    #expect(AttachmentPresentation(embed: embed).imageURL == nil)
    #expect(AttachmentPresentation(embed: embed).fileType?.conforms(to: .pdf) == true)
    embed["og"] = .object(["image": .object(["url": .string(address + "/thumbnail")])])
    #expect(AttachmentPresentation(embed: embed).imageURL == nil) // A PDF preview remains a file card.
    embed["title"] = .string("photo.png")
    #expect(AttachmentPresentation(embed: embed).imageURL?.absoluteString == address + "/thumbnail")
    embed["og"] = .object(["image": .object(["url": .string(address + "/poster")]), "video": .object(["url": .string(address)])])
    #expect(AttachmentPresentation(embed: embed).imageURL == nil)
    embed["kind"] = .string("link")
    #expect(AttachmentPresentation(embed: embed).imageURL == nil)
    let huge: JSONObject = ["og": .object(["image": .object(["width": .number(1e100), "height": .number(100)])])]
    #expect(AttachmentPresentation(embed: huge).detail == "File")
}

@MainActor @Test func attachmentThumbnailsAreBoundedAndRejectInvalidData() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 900,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let image = try #require(AttachmentPresentation.thumbnail(data))
    #expect(image.size.width <= 840)
    #expect(abs(image.size.width / image.size.height - 2) < 0.01)
    #expect(AttachmentPresentation.thumbnail(Data("not an image".utf8)) == nil)
}

@MainActor @Test func inlineImagePlaceholderReservesTheLoadedImageHeight() throws {
    // Loopback port 9 refuses connections, so the view's own load attempt stays local.
    let endpoint = URL(string: "wss://127.0.0.1:9/")!, address = "https://127.0.0.1:9/files/photo.jpg"
    let embed: JSONObject = ["kind": .string("upload"), "url": .string(address), "title": .string("photo.jpg"),
                             "og": .object(["image": .object(["url": .string(address), "width": .number(1600), "height": .number(1200)])])]
    func height(server: UUID) -> CGFloat {
        let host = NSHostingView(rootView: AttachmentView(embed: embed, endpoint: endpoint, serverID: server, account: "ada").frame(width: 500))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    let loaded = UUID()
    AttachmentRenderCache.shared.store(image: NSImage(size: CGSize(width: 840, height: 630)),
                                       AttachmentRenderCache.key(URL(string: address)!, server: loaded, account: "ada"))
    let loadedHeight = height(server: loaded)
    #expect(loadedHeight > 300)
    #expect(height(server: UUID()) == loadedHeight)
}

@MainActor @Test func viewedMessagesPersistAcrossLaunchesAndStayAccountScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, connectOnLaunch: false)
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    for id in ["100", "200", "300"] {
        server.snapshot.store.installMessage(["message_id": .string(id), "log_id": .string(id), "room_id": .string("general"),
            "from": .object(["user_id": .string("other")]), "body": .object(["text": .string(id)])])
    }
    model.saveViewedMessage("200", server: server, room: "general")
    model.saveDrafts()
    let reopened = AppModel(storage: storage, connectOnLaunch: false)
    #expect(await reopened.restoreViewedMessage(server: server, room: "general") == "200")
    #expect(await reopened.restoreViewedMessage(server: server, room: "other") == nil)
    server.profile.accountID = "ben"
    #expect(await reopened.restoreViewedMessage(server: server, room: "general") == nil)
    server.profile.accountID = "ada"
    server.snapshot.store.messages.removeValue(forKey: "200")
    #expect(await reopened.restoreViewedMessage(server: server, room: "general") == "300")
}

@MainActor @Test func readMarkerChangesAreBatchedAndFlushLatestValues() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, connectOnLaunch: false, stateSaveDelay: .milliseconds(20))
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.snapshot.phase = .ready
    let key = DraftKey(server: server.id, account: "ada", room: "general")
    model.attention.update(UUID(), key: key, readingLatest: true)
    for id in ["100", "200", "150"] { model.markRead(id, server: server, room: "general") }
    #expect(model.readMarkers[key] == "200")
    #expect(storage.read("read-markers-v1.json", as: [DraftKey: String].self) == nil)
    for _ in 0..<100 {
        if storage.read("read-markers-v1.json", as: [DraftKey: String].self)?[key] == "200" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(storage.read("read-markers-v1.json", as: [DraftKey: String].self)?[key] == "200")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("drafts-v1.json").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("viewed-messages-v1.json").path))
    model.markRead("300", server: server, room: "general")
    model.saveDrafts() // The same synchronous flush used when quitting.
    #expect(storage.read("read-markers-v1.json", as: [DraftKey: String].self)?[key] == "300")
}

@MainActor @Test func stateFlushPreservesUnchangedFilesAndPersistsPendingDrafts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = LocalStorage(directory: root)
    let model = AppModel(storage: storage, connectOnLaunch: false, stateSaveDelay: .seconds(60))
    let server = ServerModel(ServerProfile(address: "wss://chat.example/", accountID: "ada"))
    server.snapshot.phase = .ready
    let key = DraftKey(server: server.id, account: "ada", room: "general")
    model.attention.update(UUID(), key: key, readingLatest: true)
    model.setDraft(SavedDraft(text: "Pending draft"), server: server, room: "general")
    model.saveDrafts()
    let draftURL = root.appendingPathComponent("drafts-v1.json")
    let before = try FileManager.default.attributesOfItem(atPath: draftURL.path)
    let savedInode = try #require(before[.systemFileNumber] as? NSNumber)
    let savedDate = try #require(before[.modificationDate] as? Date)
    model.markRead("100", server: server, room: "general")
    model.saveDrafts()
    // LocalStorage writes atomically: an unnecessary rewrite replaces the file.
    // Read fresh stat attributes rather than URL resource values, which may cache.
    let after = try FileManager.default.attributesOfItem(atPath: draftURL.path)
    let currentInode = try #require(after[.systemFileNumber] as? NSNumber)
    let currentDate = try #require(after[.modificationDate] as? Date)
    #expect(currentInode == savedInode)
    #expect(currentDate == savedDate)
    let reopened = AppModel(storage: storage, connectOnLaunch: false)
    #expect(reopened.drafts[key]?.text == "Pending draft")
    #expect(reopened.readMarkers[key] == "100")
}

@MainActor @Test func testsAndPreviewsUseMemoryCredentials() {
    #expect(AppRuntime.isTesting)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false)
    #expect(model.credentials is MemoryCredentialStore)
    #expect(AppModel(preview: true).credentials is MemoryCredentialStore)
}

@MainActor @Test func injectedCredentialsStayIsolatedByServerAndAccount() {
    let credentials = MemoryCredentialStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false, credentials: credentials)
    credentials.save("test-token", endpoint: "wss://first.example/", account: "ada")
    #expect(model.credentials.read(endpoint: "wss://first.example/", account: "ada") == "test-token")
    #expect(model.credentials.read(endpoint: "wss://first.example/", account: "ben") == nil)
    #expect(model.credentials.read(endpoint: "wss://second.example/", account: "ada") == nil)
    credentials.delete(endpoint: "wss://first.example/", account: "ada")
    #expect(model.credentials.read(endpoint: "wss://first.example/", account: "ada") == nil)
}

@MainActor @Test func signedOutAccountsStaySavedUntilForgottenOrRemoved() {
    let credentials = MemoryCredentialStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(storage: LocalStorage(directory: root), connectOnLaunch: false, credentials: credentials)
    // A closed loopback port, so the reconnect after signing out fails fast.
    let address = "wss://127.0.0.1:9/"
    let server = ServerModel(ServerProfile(address: address))
    model.servers = [server]
    func signIn(_ account: String, guest: Bool = false) {
        credentials.save("token-" + account, endpoint: address, account: account)
        server.profile.accountID = account; server.snapshot.isGuest = guest
    }

    signIn("ada"); model.signOut(server)
    signIn("ben"); model.signOut(server)
    #expect(server.profile.accountID == nil)
    #expect(model.savedAccounts(server) == ["ben", "ada"])
    #expect(credentials.read(endpoint: address, account: "ada") == "token-ada")

    // A guest's sign-out is neither listed nor keeps its token.
    signIn("guest_1", guest: true); model.signOut(server)
    #expect(model.savedAccounts(server) == ["ben", "ada"])
    #expect(credentials.read(endpoint: address, account: "guest_1") == nil)

    model.continueAs("ada", server: server)
    #expect(server.profile.accountID == "ada" && model.savedAccounts(server) == ["ben"])
    server.snapshot.isGuest = false
    model.signOut(server)
    #expect(model.savedAccounts(server) == ["ada", "ben"])

    model.forgetSavedAccount("ben", server: server)
    #expect(credentials.read(endpoint: address, account: "ben") == nil)
    #expect(model.savedAccounts(server) == ["ada"])

    model.remove(server)
    #expect(credentials.read(endpoint: address, account: "ada") == nil)
    #expect(model.servers.isEmpty)
}

@Test func profilesWithoutSavedAccountsStillDecode() throws {
    let data = Data(#"{"id":"4F1B6C2E-8D2A-4C4E-9B3E-1C5D2E7F8A90","address":"wss://chat.example/","accountID":"ada"}"#.utf8)
    let profile = try JSONDecoder().decode(ServerProfile.self, from: data)
    #expect(profile.accountID == "ada" && profile.savedAccounts.isEmpty)
}
