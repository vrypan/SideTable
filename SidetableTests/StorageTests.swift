import Foundation
import AppKit
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
