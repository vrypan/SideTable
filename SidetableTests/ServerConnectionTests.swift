import Foundation
import Testing
import ApronCore
@testable import Sidetable

private actor ConnectionTransport: ChatTransport {
    private var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest"), .string("email"), .string("external")])])]
    private var receiver: CheckedContinuation<WireFrame, any Error>?
    private(set) var authRequests = 0
    private(set) var closed = false
    private var held: WireFrame?

    func send(_ frame: WireFrame) async throws {
        guard let id = frame.id else { return }
        if frame.method == "auth" {
            authRequests += 1
            held = WireFrame(id: id, result: ["url": .string("https://example.com/sign-in")])
        } else { push(WireFrame(id: id, result: [:])) }
    }
    func release() {
        if let held { push(held); self.held = nil }
    }
    private func push(_ frame: WireFrame) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { frames.append(frame) }
    }
    func receive() async throws -> WireFrame {
        if closed { throw ClientError.disconnected }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() {
        closed = true
        receiver?.resume(throwing: ClientError.disconnected)
        receiver = nil
    }
}

@MainActor private func waitForConnection(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
}

@MainActor @Test func replacingConnectionSuppressesOldAuthenticationCompletion() async throws {
    let firstTransport = ConnectionTransport(), secondTransport = ConnectionTransport()
    let first = ApronSession(transportFactory: { firstTransport })
    let second = ApronSession(transportFactory: { secondTransport })
    var sessions = [first, second]
    var tokens: [String?] = []
    let connection = ServerConnection(makeSession: { _, token in
        tokens.append(token)
        return sessions.removeFirst()
    })
    defer { connection.stop() }
    let url = try #require(URL(string: "wss://example.com/"))
    var error: String? = "previous error"
    connection.connect(url: url, token: "saved-token", seed: nil, pageLimit: 5, available: { true }, receive: { _ in })
    try await waitForConnection { await first.snapshot().phase == .signIn }
    connection.requestEmail("ada@example.com", reportError: { error = $0 })
    #expect(connection.busy && error == nil)
    // Repeated actions are ignored while the first request is outstanding.
    connection.requestEmail("ben@example.com", reportError: { error = $0 })
    try await waitForConnection { await firstTransport.authRequests == 1 }
    connection.connect(url: url, token: nil, seed: nil, pageLimit: 5, available: { true }, receive: { _ in })
    #expect(!connection.busy && connection.session === second)
    try await waitForConnection { await second.snapshot().phase == .signIn }
    connection.requestEmail("ben@example.com", reportError: { error = $0 })
    try await waitForConnection { await secondTransport.authRequests == 1 }
    #expect(connection.busy && error == nil)
    #expect(await firstTransport.closed)
    #expect(tokens.count == 2 && tokens[0] == "saved-token" && tokens[1] == nil)
    await secondTransport.release()
    try await waitForConnection { !connection.busy }
    #expect(error == nil)
}

@MainActor @Test func externalSignInReportsBrowserFailureAndReleasesBusyState() async throws {
    let transport = ConnectionTransport()
    let session = ApronSession(transportFactory: { transport })
    var opened: [URL] = []
    let connection = ServerConnection(makeSession: { _, _ in session }, openURL: { opened.append($0); return false })
    defer { connection.stop() }
    connection.connect(url: try #require(URL(string: "wss://example.com/")), token: nil, seed: nil,
                       pageLimit: 5, available: { true }, receive: { _ in })
    try await waitForConnection { await session.snapshot().phase == .signIn }
    var error: String?
    connection.requestExternalSignIn(reportError: { error = $0 })
    try await waitForConnection { await transport.authRequests == 1 }
    await transport.release()
    try await waitForConnection { !connection.busy }
    #expect(opened.map(\.absoluteString) == ["https://example.com/sign-in"])
    #expect(error == "The sign-in page could not be opened. Check your default browser and try again.")
}

@MainActor @Test func releasingConnectionStopsItsSessionAndListener() async throws {
    let transport = ConnectionTransport()
    let session = ApronSession(transportFactory: { transport })
    var connection: ServerConnection? = ServerConnection(makeSession: { _, _ in session })
    weak var released = connection
    var receivedSignIn = false
    connection?.connect(url: try #require(URL(string: "wss://example.com/")), token: nil, seed: nil,
                        pageLimit: 5, available: { true }, receive: { event in
        if case .snapshot(let value) = event, value.phase == .signIn { receivedSignIn = true }
    })
    try await waitForConnection { receivedSignIn }
    connection = nil
    #expect(released == nil)
    try await waitForConnection { await transport.closed }
}
