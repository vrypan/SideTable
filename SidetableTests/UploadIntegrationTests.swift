import Foundation
import Testing
import ApronCore
@testable import Sidetable

// Opt in against a disposable reference server on loopback; never uses public servers.
// TEST_RUNNER_SIDETABLE_UPLOAD_INTEGRATION=1 make test-app
@Test(.enabled(if: ProcessInfo.processInfo.environment["SIDETABLE_UPLOAD_INTEGRATION"] == "1"))
@MainActor func uploadThroughReferenceServer() async throws {
    let endpoint = URL(string: "ws://127.0.0.1:18080/ws")!
    let session = ApronSession(url: endpoint, requestTimeout: .seconds(5))
    let coordinator = UploadCoordinator()
    let listener = Task {
        for await event in session.events {
            if case .snapshot(let snapshot) = event { coordinator.reconcile(snapshot.store) }
        }
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
    try Data("Sidetable native upload integration\n".utf8).write(to: file)
    defer { coordinator.reset(); listener.cancel(); try? FileManager.default.removeItem(at: file) }
    await session.start()
    do {
        for _ in 0..<100 where await session.snapshot().phase != .signIn { try await Task.sleep(for: .milliseconds(50)) }
        try await session.authenticate(scheme: "guest", fields: ["name": .string("Sidetable upload test")])
        let snapshot = await session.snapshot()
        let room = try #require(snapshot.store.joined.sorted().first)
        let params: JSONObject = ["room_id": .string(room), "body": .object(["text": .string("Upload integration"), "embeds": .array([.object(["kind": .string("upload"), "title": .string(file.lastPathComponent)])])])]
        let message = PendingMessage(id: UUID().uuidString, room: room, account: snapshot.you.string("user_id")!, params: params, text: "Upload integration", files: [StagedFile(url: file)])
        coordinator.messages = [message]
        var submissions = 0
        var originalWriteURL: URL?
        coordinator.submit(message, endpoint: endpoint) { method, params, id in
            submissions += 1
            _ = try await session.perform(method, params: params, id: id)
            throw URLError(.networkConnectionLost) // Simulate losing only the acknowledgement.
        }
        for _ in 0..<100 where message.sending { try await Task.sleep(for: .milliseconds(50)) }
        #expect(message.error != nil)
        coordinator.submit(message, endpoint: endpoint) { method, params, id in
            submissions += 1
            let result = try await session.perform(method, params: params, id: id)
            originalWriteURL = result.objects("embeds").first?.string("write_url").flatMap(URL.init(string:))
            return result
        }
        for _ in 0..<200 where message.uploads[0].phase != .complete { try await Task.sleep(for: .milliseconds(50)) }
        #expect(message.uploads[0].phase == .complete)
        #expect(submissions == 2)
        let state = await session.snapshot()
        let matches = state.store.messages.values.filter { $0.string("message_id") == message.messageID }
        #expect(matches.count == 1)
        let address = try #require(matches.first?.object("body").objects("embeds").first?.string("url"))
        let download = try #require(URL(string: address))
        #expect(MediaPolicy.allows(download, endpoint: endpoint))
        let (data, _) = try await URLSession.shared.data(from: download)
        #expect(data == Data("Sidetable native upload integration\n".utf8))
        // The server omits consumed write URLs from later dedup responses.
        let duplicate = try await session.perform("message", params: params, id: message.id)
        #expect(duplicate.objects("embeds").isEmpty)
        let write = try #require(originalWriteURL)
        do { try await FileUploader.live.transfer(file, write, endpoint) { _, _ in }; Issue.record("Used upload URL accepted") }
        catch let failure as UploadFailure { #expect(failure.mayHaveConsumedURL) }
        await session.stop()
    } catch { await session.stop(); throw error }
}
