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
    #expect(store.reactionSummary("10") == ["❤️": ["ada"]])
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
