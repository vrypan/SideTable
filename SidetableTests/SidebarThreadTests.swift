import Testing
import ApronCore
@testable import Sidetable

@Test func sidebarThreadsUseNumericActivityAndLoadedMessages() {
    var store = RecordStore()
    store.rooms = [
        "old": ["room_id": .string("old"), "parent_room_id": .string("parent"), "latest_log_id": .string("9"), "title": .string("A")],
        "recent": ["room_id": .string("recent"), "parent_room_id": .string("parent"), "latest_log_id": .string("100"), "title": .string("Z"), "description": .string("A **useful**\nsummary")],
        "other": ["room_id": .string("other"), "parent_room_id": .string("elsewhere"), "latest_log_id": .string("999")]
    ]
    #expect(SidebarThread.entries(store: store, parent: "parent", unread: [:]).map(\.id) == ["recent", "old"])
    store.messages["101"] = ["message_id": .string("101"), "log_id": .string("101"), "room_id": .string("old"), "from": .object(["user_id": .string("ada")]), "body": .object(["text": .string("New reply")])]
    let entries = SidebarThread.entries(store: store, parent: "parent", unread: ["old": 2])
    #expect(entries.map(\.id) == ["old", "recent"])
    #expect(entries[0].unread == 2)
    #expect(entries[0].summary.contains("New reply"))
    #expect(entries[1].summary == "A useful summary")
    store.messages["101"]?["deleted"] = .bool(true)
    #expect(SidebarThread.entries(store: store, parent: "parent", unread: [:])[0].summary.isEmpty)
}

@Test func sidebarThreadGroupsKeepSelectedAndUnreadVisibleInActivityOrder() {
    let entries = (0..<9).map { SidebarThread(id: String($0), title: "Thread", summary: "", activity: UInt64(10 - $0), unread: $0 == 7 ? 3 : 0) }
    let groups = SidebarThread.groups(entries, selected: "6")
    #expect(groups.recent.map(\.id) == ["0", "1", "2", "3", "6", "7"])
    #expect(groups.older.map(\.id) == ["4", "5", "8"])
}

@Test func sidebarThreadActivityTiesHaveStableOrderingAndDescriptionsWin() {
    var store = RecordStore()
    for id in ["b", "a"] {
        store.rooms[id] = ["room_id": .string(id), "parent_room_id": .string("parent"), "description": .string("Summary")]
    }
    #expect(SidebarThread.entries(store: store, parent: "parent", unread: [:]).map(\.id) == ["a", "b"])
    store.messages["1"] = ["message_id": .string("1"), "log_id": .string("1"), "room_id": .string("a"), "body": .object(["text": .string("Message")])]
    #expect(SidebarThread.entries(store: store, parent: "parent", unread: [:])[0].summary == "Summary")
}
