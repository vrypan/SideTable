// Compile with Wire.swift and Store.swift; see docs/testing.md.
import Foundation

@main
struct TranscriptBenchmark {
    static func main() {
        var source = RecordStore()
        var messages: [String: JSONObject] = [:]
        for id in 1...5000 {
            messages[String(id)] = ["message_id": .string(String(id)), "room_id": .string("room-\(id % 5)")]
            for user in ["ada", "ben"] {
                source.reactions[RecordKey(String(id), user)] = ["emojis": .array([.string("👍")])]
            }
        }
        source.messages = messages
        let store = source
        func baselineTimeline(_ room: String) -> [JSONObject] {
            store.messages.values.filter { $0.string("room_id") == room }
                .sorted { ($0.logID("message_id") ?? 0) < ($1.logID("message_id") ?? 0) }
        }
        func baselineReactions(_ message: String) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for (key, value) in store.reactions where key.first == message {
                for emoji in value.strings("emojis") { result[emoji, default: []].append(key.second) }
            }
            return result.mapValues { $0.sorted() }
        }
        func run(_ label: String, timeline: (String) -> [JSONObject], reactions: (String) -> [String: [String]]) -> Int {
            let start = ProcessInfo.processInfo.systemUptime
            var checksum = 0
            for _ in 0..<20 {
                for room in 0..<5 { checksum += timeline("room-\(room)").count }
                for id in 1...150 { checksum += reactions(String(id))["👍"]?.count ?? 0 }
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print(String(format: "%@: %.2f ms (checksum %d)", label, milliseconds, checksum))
            return checksum
        }
        let baseline = run("Repeated scans", timeline: baselineTimeline, reactions: baselineReactions)
        // Includes the initial lazy index construction, not just warm lookups.
        let cached = run("Cached derivation", timeline: store.timeline, reactions: store.reactionSummary)
        precondition(baseline == cached)
        for room in 0..<5 { precondition(store.timeline("room-\(room)") == baselineTimeline("room-\(room)")) }
        for id in 1...150 { precondition(store.reactionSummary(String(id)) == baselineReactions(String(id))) }
        var live = store
        let start = ProcessInfo.processInfo.systemUptime
        for version in 10_000..<10_100 {
            live.installMessage(["message_id": .string("5"), "room_id": .string("room-0"),
                                 "log_id": .string(String(version)), "from": .object(["user_id": .string("ada")])])
            for room in 0..<5 { precondition(live.timeline("room-\(room)").count == 1000) }
        }
        print(String(format: "100 single-room updates with all rooms read: %.2f ms",
                     (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
