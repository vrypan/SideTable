import Foundation
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
