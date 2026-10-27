import Foundation
import Testing
import ApronCore
@testable import Sidetable

private actor TransferHarness {
    var calls: [String] = []
    var blocked: [String: CheckedContinuation<Void, Never>] = [:]
    var failure: String?
    var gate = false
    init(failure: String? = nil, gate: Bool = false) { self.failure = failure; self.gate = gate }
    func transfer(_ file: URL, progress: UploadProgress) async throws {
        calls.append(file.lastPathComponent)
        progress(5, 10)
        if gate { await withCheckedContinuation { blocked[file.lastPathComponent] = $0 } }
        if file.lastPathComponent == failure { throw UploadFailure(message: "Single-use link expired. Reattach the file.", mayHaveConsumedURL: true) }
        progress(10, 10)
    }
    func release() { for continuation in blocked.values { continuation.resume() }; blocked = [:] }
    func count() -> Int { calls.count }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition(), "Timed out waiting for state transition")
}

@MainActor private func pending(_ names: [String] = ["a.txt"]) -> PendingMessage {
    PendingMessage(id: "operation", room: "general", account: "ada", params: ["body": .object(["text": .string("hello")])], text: "hello",
                   files: names.map { StagedFile(url: URL(fileURLWithPath: "/tmp/" + $0)) })
}
private func response(_ count: Int = 1) -> JSONObject {
    ["message_id": .string("100"), "embeds": .array((0..<count).map {
        .object(["kind": .string("upload"), "embed_id": .string("e\($0)"), "write_url": .string("https://chat.example/write/\($0)")])
    })]
}
private let endpoint = URL(string: "wss://chat.example/")!

@MainActor @Test func uncertainAcknowledgementRetainsFilesAndOperationIdentity() async throws {
    let harness = TransferHarness()
    let coordinator = UploadCoordinator(uploader: FileUploader { file, _, _, progress in try await harness.transfer(file, progress: progress) })
    let message = pending(); coordinator.messages = [message]
    var ids: [String] = []
    coordinator.submit(message, endpoint: endpoint) { _, _, id in ids.append(id); throw URLError(.timedOut) }
    try await eventually { !message.sending }
    #expect(message.uploads[0].file != nil)
    coordinator.submit(message, endpoint: endpoint) { _, _, id in ids.append(id); return response() }
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in Issue.record("Duplicate in-flight submission"); return [:] }
    try await eventually { message.uploads[0].phase == .confirming }
    #expect(ids == ["operation", "operation"])
    #expect(await harness.count() == 1)
    #expect(message.acknowledged && message.messageID == "100")
    coordinator.reset()
}

@MainActor @Test func partialSuccessWaitsForSnapshotAndNeverRetriesConsumedURL() async throws {
    let harness = TransferHarness(failure: "b.txt")
    let coordinator = UploadCoordinator(uploader: FileUploader { file, _, _, progress in try await harness.transfer(file, progress: progress) })
    let message = pending(["a.txt", "b.txt"]); coordinator.messages = [message]
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in response(2) }
    try await eventually { message.uploads[0].phase == .confirming && message.uploads[1].phase == .failed }
    #expect(!message.uploads[1].canRetry)
    coordinator.start(message.uploads[1], message: message, endpoint: endpoint)
    #expect(await harness.count() == 2)
    var store = RecordStore()
    store.installMessage(["message_id": .string("100"), "log_id": .string("101"), "room_id": .string("general"), "from": .object(["user_id": .string("ada")]),
                          "body": .object(["embeds": .array([.object(["embed_id": .string("e0"), "url": .string("https://chat.example/files/a")])])])])
    coordinator.reconcile(store)
    #expect(message.uploads[0].phase == .complete)
    #expect(message.uploads[0].file == nil)
    #expect(message.uploads[1].phase == .failed)
    coordinator.reset()
}

@MainActor @Test func cancellationAndAccountResetIgnoreLateCallbacks() async throws {
    let harness = TransferHarness(gate: true)
    let coordinator = UploadCoordinator(uploader: FileUploader { file, _, _, progress in try await harness.transfer(file, progress: progress) })
    let message = pending(); coordinator.messages = [message]
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in response() }
    try await eventually { message.uploads[0].bytes == 5 }
    let upload = message.uploads[0]
    coordinator.cancel(upload)
    #expect(upload.phase == .cancelled && !upload.canRetry)
    coordinator.reset()
    #expect(coordinator.messages.isEmpty && upload.file == nil)
    await harness.release()
    try await Task.sleep(for: .milliseconds(20))
    #expect(upload.phase == .cancelled && upload.bytes == 5)
}

@MainActor @Test func malformedResponseCannotSilentlyDropFiles() async throws {
    let coordinator = UploadCoordinator(uploader: FileUploader { _, _, _, _ in Issue.record("Must not upload malformed mapping") })
    let message = pending(["a", "b"]); coordinator.messages = [message]
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in response(1) }
    try await eventually { !message.sending }
    #expect(message.uploads.allSatisfy { $0.phase == .failed && $0.file != nil })
    coordinator.reset()
}

@MainActor @Test func linkEmbedsDoNotChangeUploadDescriptorMapping() async throws {
    let harness = TransferHarness()
    let coordinator = UploadCoordinator(uploader: FileUploader { file, _, _, progress in try await harness.transfer(file, progress: progress) })
    let params: JSONObject = ["body": .object(["embeds": .array([
        .object(["kind": .string("upload"), "title": .string("a.txt")]),
        .object(["kind": .string("link"), "url": .string("https://example.com/")]),
        .object(["kind": .string("upload"), "title": .string("b.txt")])
    ])])]
    let message = PendingMessage(id: "mixed", room: "general", account: "ada", params: params, text: "https://example.com/",
        files: [StagedFile(url: URL(fileURLWithPath: "/tmp/a.txt")), StagedFile(url: URL(fileURLWithPath: "/tmp/b.txt"))])
    coordinator.messages = [message]
    coordinator.submit(message, endpoint: endpoint) { _, sent, _ in
        #expect(sent == params)
        return response(2) // Apron returns descriptors for writes only, in upload order.
    }
    try await eventually { message.uploads.allSatisfy { $0.phase == .confirming } }
    #expect(message.uploads.map(\.embedID) == ["e0", "e1"])
    #expect(await harness.count() == 2)
    coordinator.reset()
}

@MainActor @Test func accountResetDuringAcknowledgementCannotStartTransfer() async throws {
    let coordinator = UploadCoordinator(uploader: FileUploader { _, _, _, _ in Issue.record("Old account upload started") })
    let message = pending(); coordinator.messages = [message]
    var continuation: CheckedContinuation<JSONObject, Never>?
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in await withCheckedContinuation { continuation = $0 } }
    try await eventually { continuation != nil }
    coordinator.reset(); continuation?.resume(returning: response())
    try await Task.sleep(for: .milliseconds(20))
    #expect(coordinator.messages.isEmpty && !message.acknowledged)
}

@Test func uploaderRejectsUntrustedOriginAndMissingFilesBeforeNetwork() async {
    for (file, url) in [(URL(fileURLWithPath: "/tmp/missing-sidetable-file"), URL(string: "https://evil.example/write/secret")!),
                        (URL(fileURLWithPath: "/tmp/missing-sidetable-file"), URL(string: "https://chat.example/write/secret")!)] {
        do { try await FileUploader.live.transfer(file, url, endpoint) { _, _ in }; Issue.record("Expected preflight failure") }
        catch let error as UploadFailure {
            #expect(!error.mayHaveConsumedURL)
            #expect(!error.message.contains("secret"))
        } catch { Issue.record("Expected sanitized upload error") }
    }
}

private final class UploadHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url!.lastPathComponent) ?? 500
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func httpFailuresAreSanitizedAndSuccessfulPUTReturns() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("attachment".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let uploader = FileUploader.configured {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadHTTPStub.self]
        return configuration
    }
    for status in [201, 302, 404, 413, 500] {
        do {
            try await uploader.transfer(file, URL(string: "https://chat.example/secret/\(status)")!, endpoint) { _, _ in }
            #expect(status == 201)
        } catch let error as UploadFailure {
            #expect(status != 201 && error.mayHaveConsumedURL)
            #expect(!error.message.contains("secret"))
        }
    }
}

private actor PreflightFailureHarness {
    var calls: [String: Int] = [:]
    func transfer(_ file: URL, _ progress: UploadProgress) throws {
        calls[file.lastPathComponent, default: 0] += 1
        if file.lastPathComponent == "retry.txt", calls["retry.txt"] == 1 { throw UploadFailure(message: "Local file unavailable", mayHaveConsumedURL: false) }
        progress(10, 10)
    }
}

@MainActor @Test func retryBeforeNetworkOnlyRepeatsTheFailedFile() async throws {
    let harness = PreflightFailureHarness()
    let coordinator = UploadCoordinator(uploader: FileUploader { file, _, _, progress in try await harness.transfer(file, progress) })
    let message = pending(["retry.txt", "success.txt"]); coordinator.messages = [message]
    var submissions = 0
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in submissions += 1; return response(2) }
    try await eventually { message.uploads[0].phase == .failed }
    #expect(message.uploads[0].canRetry)
    coordinator.start(message.uploads[0], message: message, endpoint: endpoint)
    coordinator.start(message.uploads[0], message: message, endpoint: endpoint)
    try await eventually { message.uploads[0].phase == .confirming }
    #expect(submissions == 1)
    #expect(await harness.calls == ["retry.txt": 2, "success.txt": 1])
    coordinator.reset()
}

@MainActor @Test func reattachReturnsOnlyTheSelectedFileToItsOriginalRoom() {
    let model = AppModel(preview: true)
    let server = model.servers[0]
    let message = pending(["a.txt", "b.txt"])
    server.uploads.messages = [message]
    message.acknowledged = true
    message.uploads[1].phase = .failed
    model.reattach(message.uploads[1], message: message, server: server)
    #expect(server.files["general"]?.map(\.name) == ["b.txt"])
    #expect(message.uploads[1].file == nil)
    #expect(message.uploads[0].file != nil)
    #expect(server.pending.count == 1)
    server.uploads.reset()
}

@MainActor @Test func missingMessageIdentityCannotWaitForConfirmationForever() async throws {
    let coordinator = UploadCoordinator(uploader: FileUploader { _, _, _, _ in Issue.record("Malformed acknowledgement started upload") })
    let message = pending(); coordinator.messages = [message]
    coordinator.submit(message, endpoint: endpoint) { _, _, _ in
        var result = response(); result.removeValue(forKey: "message_id"); return result
    }
    try await eventually { !message.sending }
    #expect(message.uploads[0].phase == .failed)
    coordinator.reset()
}
