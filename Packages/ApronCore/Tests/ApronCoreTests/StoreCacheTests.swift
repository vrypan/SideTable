import Foundation
import Testing
@testable import ApronCore

private func message(_ id: String, room: String, log: String? = nil, deleted: Bool = false) -> JSONObject {
    ["message_id": .string(id), "log_id": .string(log ?? id), "room_id": .string(room),
     "from": .object(["user_id": .string("ada")]), "deleted": .bool(deleted)]
}

@Test func derivedTimelinesFollowMovesDeletesAndDirectMutationsWithoutChangingCopies() {
    var store = RecordStore()
    store.installMessage(message("10", room: "a"))
    store.installMessage(message("2", room: "a"))
    #expect(store.timeline("a").compactMap { $0.string("message_id") } == ["2", "10"])
    let saved = store
    store.installMessage(message("2", room: "b", log: "20"))
    #expect(store.timeline("a").compactMap { $0.string("message_id") } == ["10"])
    #expect(store.timeline("b").compactMap { $0.string("message_id") } == ["2"])
    store.messages["10"]?["body"] = .object(["text": .string("edited directly")])
    #expect(store.timeline("a").first?.object("body").string("text") == "edited directly")
    store.clearRoom("b")
    #expect(store.timeline("b").isEmpty)
    #expect(saved.timeline("a").count == 2 && saved.timeline("b").isEmpty)
    var identical = RecordStore()
    identical.messages = saved.messages
    #expect(identical == saved) // Cache population is not part of value equality.
}

@Test func derivedReactionsFollowReplacementRedactionAndRoomClearing() {
    var store = RecordStore()
    store.installMessage(message("10", room: "a"))
    let key = RecordKey("10", "ada")
    store.reactions[key] = ["emojis": .array([.string("👍")]), "room_id": .string("a")]
    #expect(store.reactionSummary("10") == ["👍": ["ada"]])
    let saved = store
    store.reactions[key]?["emojis"] = .array([.string("❤️")])
    #expect(store.reactionSummary("10") == ["❤": ["ada"]])
    store.installMessage(message("10", room: "a", log: "20", deleted: true))
    #expect(store.reactionSummary("10").isEmpty)
    store.clearRoom("a")
    #expect(store.reactionSummary("10").isEmpty)
    #expect(saved.reactionSummary("10") == ["👍": ["ada"]])
}

@Test func immutableSnapshotsCanDeriveTimelinesAndReactionsConcurrently() async {
    var source = RecordStore()
    for id in 1...100 {
        source.installMessage(message(String(id), room: "a"))
        source.reactions[RecordKey(String(id), "ada")] = ["emojis": .array([.string("👍")])]
    }
    let snapshot = source
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask {
                #expect(snapshot.timeline("a").count == 100)
                #expect(snapshot.reactionSummary("50") == ["👍": ["ada"]])
            }
        }
    }
}

@Test func transientNoticesRecordWhereTheyArrivedWithoutBecomingMessages() {
    var store = RecordStore()
    store.installMessage(["room_id": .string("a"), "from": .object(["user_id": .string("~private")]), "body": .object(["text": .string("welcome")])])
    store.installMessage(message("10", room: "a"))
    store.installMessage(message("20", room: "b"))
    store.installMessage(["room_id": .string("a"), "from": .object(["user_id": .string("~private")]), "body": .object(["text": .string("reply")])])
    store.installMessage(["from": .object(["user_id": .string("~private")]), "body": .object(["text": .string("no room")])])
    // Older history loaded later does not move a notice.
    store.installMessage(message("5", room: "a"))
    #expect(store.notices.map(\.after) == [nil, 20, 20])
    #expect(store.timeline("a").compactMap { $0.string("message_id") } == ["5", "10"])
}

@Test func messageUpdatesReuseUnrelatedRoomTimelinesAndPreserveOldSnapshots() {
    var store = RecordStore()
    for id in 1...100 {
        store.installMessage(message(String(id), room: id <= 50 ? "a" : "b"))
    }
    let original = store
    let unchanged = store.timeline("b")
    store.installMessage(message("1", room: "a", log: "101"))
    let reused = store.timeline("b")
    unchanged.withUnsafeBufferPointer { old in
        reused.withUnsafeBufferPointer { new in
            #expect(old.baseAddress == new.baseAddress) // No regrouping or sorting for room b.
        }
    }
    #expect(original.timeline("a").first?.string("log_id") == "1")
    #expect(store.timeline("a").first?.string("log_id") == "101")
    store.installMessage(message("1", room: "b", log: "102"))
    #expect(store.timeline("a").count == 49 && store.timeline("b").count == 51)
    #expect(original.timeline("a").count == 50 && original.timeline("b").count == 50)
    store.clearRoom("a")
    #expect(store.timeline("a").isEmpty && store.timeline("b").count == 51)
    store.messages["1"] = nil // Public direct mutations must still rebuild the index.
    #expect(store.timeline("b").count == 50)
}

@Test func noticesFollowTheLatestHeldMessageAfterRoomsChange() {
    func message(_ id: String, room: String) -> JSONObject {
        ["message_id": .string(id), "log_id": .string(id), "room_id": .string(room), "from": .object(["user_id": .string("ada")])]
    }
    var store = RecordStore()
    store.installMessage(message("100", room: "general"))
    store.installMessage(message("300", room: "random"))
    store.installMessage(["body": .object(["text": .string("first")])])
    #expect(store.notices.last?.after == 300)
    // Clearing the room that held the latest message falls back to what remains.
    store.clearRoom("random")
    store.installMessage(["body": .object(["text": .string("second")])])
    #expect(store.notices.last?.after == 100)
    store.messages = [:]
    store.installMessage(["body": .object(["text": .string("third")])])
    #expect(store.notices.last?.after == nil)
}
