import Foundation
import ApronCore

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("Usage: apron-probe <ws(s) URL> [--local-mutations] [--local-history]"); return }
        let url = try ServerAddress.normalize(args[1])
        let mutations = args.contains("--local-mutations") || args.contains("--local-history")
        if mutations && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") {
            throw RPCError(code: 1, message: "Mutation probes are restricted to loopback servers.")
        }
        let session = ApronSession(url: url)
        let drain = Task {
            var last: ConnectionPhase?
            for await event in session.events {
                if case .snapshot(let snapshot) = event, last != snapshot.phase {
                    last = snapshot.phase
                    FileHandle.standardError.write(Data("State: \(snapshot.phase.rawValue)\(snapshot.error.map { " — " + $0 } ?? "")\n".utf8))
                }
            }
        }
        await session.start()
        do {
            try await wait(session, phase: .signIn)
            let announcement = await session.snapshot()
            print("Protocol: \(announcement.server["apron"]?.number ?? 0); capabilities: \(announcement.server.strings("capabilities").sorted().joined(separator: ", "))")
            try await session.authenticate(scheme: "guest", fields: ["name": .string("Sidetable compatibility check")])
            var view = await session.snapshot()
            guard view.phase == .ready else { throw ClientError.notReady }
            print("Guest sign-in succeeded; \(view.store.joined.count) joined rooms; \(view.store.messages.count) recovered message snapshots.")
            if let room = view.store.joined.sorted().first { try await session.loadRoom(room) }
            if mutations {
                let created = try await session.perform("room_set", params: ["title": .string("Sidetable integration \(UUID().uuidString.prefix(8))")])
                let room = created.string("room_id")!
                let params: JSONObject = ["room_id": .string(room), "body": .object(["text": .string("Sidetable integration message")])]
                let operation = UUID().uuidString
                let posted = try await session.perform("message", params: params, id: operation)
                let id = posted.string("message_id")!
                let duplicate = try await session.perform("message", params: params, id: operation)
                guard duplicate.string("message_id") == id else { throw RPCError(code: 2, message: "Deduplication failed") }
                _ = try await session.perform("reactions", params: ["message_id": .string(id), "emojis": .array([.string("👍")])])
                _ = try await session.perform("message", params: ["message_id": .string(id), "room_id": .string(room), "body": .object(["text": .string("Edited integration message")])])
                let thread = try await session.perform("room_set", params: ["title": .string("Integration thread"), "parent_room_id": .string(room)])
                _ = try await session.perform("message", params: ["message_id": .string(id), "room_id": thread["room_id"]!, "body": .object(["text": .string("Moved integration message")])])
                try await session.loadRoom(thread.string("room_id")!)
                view = await session.snapshot()
                guard view.store.messages[id]?.string("room_id") == thread.string("room_id") else { throw RPCError(code: 3, message: "Move/recovery failed") }
                _ = try await session.perform("message", params: ["message_id": .string(id), "room_id": thread["room_id"]!, "deleted": .bool(true)])
                view = await session.snapshot()
                guard view.store.messages[id]?.bool("deleted") == true else { throw RPCError(code: 4, message: "Deletion failed") }
                await session.reconnect()
                try await wait(session, phase: .ready)
                try await session.loadRoom(thread.string("room_id")!)
                view = await session.snapshot()
                guard view.store.messages[id]?.bool("deleted") == true else { throw RPCError(code: 5, message: "Deleted message resurrected after reconnect") }
                print("Local room/thread creation, send, deduplication, reaction, edit, move, history, deletion, and reconnect passed.")
            }
            if args.contains("--local-history") { try await verifyHistory(session, url: url) }
            await session.stop(); drain.cancel()
            print("Disconnected cleanly.\(mutations ? "" : " No messages posted.")")
        } catch {
            await session.stop(); drain.cancel(); throw error
        }
    }
    static func verifyHistory(_ writer: ApronSession, url: URL) async throws {
        let created = try await writer.perform("room_set", params: ["title": .string("History pagination \(UUID().uuidString.prefix(8))"), "private": .bool(false)])
        let room = created.string("room_id")!
        var ids: Set<String> = []
        for index in 0..<240 {
            let result = try await writer.perform("message", params: ["room_id": .string(room), "body": .object(["text": .string("History fixture \(index)")])])
            ids.insert(result.string("message_id")!)
        }
        let reader = ApronSession(url: url)
        do {
            await reader.start(); try await wait(reader, phase: .signIn)
            try await reader.authenticate(scheme: "guest", fields: ["name": .string("SideTable history reader")])
            _ = try await reader.perform("room_join", params: ["room_id": .string(room)])
            try await reader.loadRoom(room)
            var view = await reader.snapshot()
            let recent = view.store.timeline(room).count
            guard recent > 0, recent <= 200, view.roomHistory(room)?.hasOlder == true else {
                throw RPCError(code: 6, message: "Initial history was not a bounded recent page")
            }
            var pages = 0
            while view.roomHistory(room)?.hasOlder == true, pages < 10 {
                try await reader.loadOlderHistory(room); pages += 1; view = await reader.snapshot()
            }
            guard view.roomHistory(room)?.hasOlder == false,
                  Set(view.store.timeline(room).compactMap { $0.string("message_id") }) == ids else {
                throw RPCError(code: 7, message: "Backward pagination lost or duplicated fixture messages")
            }
            await reader.stop()
            print("History pagination passed: \(recent) recent messages, \(pages) older pages, 240 unique messages.")
        } catch { await reader.stop(); throw error }
    }
    static func wait(_ session: ApronSession, phase: ConnectionPhase) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let snapshot = await session.snapshot()
            if snapshot.phase == phase { return }
            if let error = snapshot.error { throw RPCError(code: 1, message: error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClientError.timeout
    }
}
