import Foundation
import Testing
@testable import ApronCore

@Test func upstreamReplayFixtures() throws {
    let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/replay")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    #expect(files.count == 17)
    for file in files.sorted(by: { $0.path < $1.path }) {
        let fixture = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: file))
        for variant in fixture.objects("variants") {
            var store = RecordStore()
            for step in variant.objects("steps") {
                if let receive = step["receive"] {
                    let frame = try JSONDecoder().decode(WireFrame.self, from: JSONEncoder().encode(receive))
                    if let result = frame.result {
                        store.applyHistory(result)
                        if result["joined"] != nil || result["not_joined"] != nil { store.applyListing(result) }
                    }
                    else { store.apply(frame) }
                }
                if let expected = step["expect"]?.object { check(store, expected, file.lastPathComponent, variant.string("name") ?? "") }
            }
            check(store, fixture.object("expected"), file.lastPathComponent, variant.string("name") ?? "")
        }
    }
}

private func check(_ store: RecordStore, _ expected: JSONObject, _ file: String, _ variant: String) {
    let ids = Set(store.rooms.keys).union(store.messages.values.compactMap { $0.string("room_id") }).sorted()
    let expectedRooms = expected.objects("rooms")
    #expect(ids == expectedRooms.compactMap { $0.string("room_id") }.sorted(), "\(file) / \(variant): room IDs")
    for expectedRoom in expectedRooms {
        let id = expectedRoom.string("room_id")!
        var actual = (store.rooms[id] ?? ["room_id": .string(id)]).filter { !["latest_log_id", "history_log_id", "member_count"].contains($0.key) }
        var messages = store.timeline(id)
        for index in messages.indices {
            let summary = store.reactionSummary(messages[index].string("message_id")!)
            if !summary.isEmpty {
                messages[index]["reactions"] = .array(summary.keys.sorted().map { emoji in
                    .object(["emoji": .string(emoji), "user_ids": .array(summary[emoji]!.map(JSONValue.string))])
                })
            }
        }
        actual["messages"] = .array(messages.map(JSONValue.object))
        if expectedRoom["members"] != nil {
            actual["members"] = .array((store.members[id] ?? []).sorted().map { user in
                .object(store.memberObjects[RecordKey(id, user)] ?? ["user_id": .string(user)])
            })
        }
        #expect(actual == expectedRoom, "\(file) / \(variant): \(id)")
    }
}

@Test func logIDsAndAddresses() throws {
    #expect(LogID("9")! < LogID("10")!)
    for invalid in ["", "0", "01", "-1", "1.0", "9007199254740992", "a"] { #expect(LogID(invalid) == nil) }
    #expect(try ServerAddress.normalize("chat.example").absoluteString == "wss://chat.example/")
    #expect(try ServerAddress.normalize("ws://localhost:8080/ws").path == "/ws")
    #expect(throws: ClientError.self) { try ServerAddress.normalize("ws://chat.example") }
    #expect(throws: ClientError.self) { try ServerAddress.normalize("wss://name:secret@chat.example") }
}

@Test func recoveryUsesSliceBoundsAndDetectsRetention() throws {
    var cursor = RecoveryCursor(checkpoint: 100)
    let page: JSONObject = ["latest_log_id": .string("1000"), "history_log_id": .string("90"), "first_log_id": .string("200"), "last_log_id": .string("700"), "more": .bool(true)]
    #expect(try !cursor.inspect(page))
    #expect(try cursor.advance(page))
    #expect(cursor.next == 701)
    #expect(cursor.head == 1000)
    #expect(try cursor.inspect(["latest_log_id": .string("2000"), "history_log_id": .string("1500")]))
    #expect(cursor.next == 1500)
    #expect(cursor.head == 2000)
    #expect(try cursor.inspect(["latest_log_id": .string("2000"), "history_log_id": .null]))
    #expect(cursor.next == 2001)
}

@Test func sameVersionRedactionAndIdentityClears() {
    var store = RecordStore()
    let record: JSONObject = ["message_id": .string("100"), "log_id": .string("100"), "room_id": .string("r"), "from": .object(["user_id": .string("u")]), "body": .object(["text": .string("secret")])]
    store.installMessage(record)
    var deleted = record; deleted["deleted"] = .bool(true)
    store.installMessage(deleted); store.installMessage(record)
    #expect(store.messages["100"]?["body"] == nil)
    store.mergeUser(["user_id": .string("u"), "name": .string("Ada")], complete: true)
    store.mergeUser(["user_id": .string("u"), "name": .string("")])
    #expect(store.displayName(["user_id": .string("u"), "name": .string("Stale")]) == "u")
}
