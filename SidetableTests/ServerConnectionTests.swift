import Foundation
import Testing
import ApronCore
@testable import Sidetable

private actor ConnectionTransport: ChatTransport {
    private var frames = [WireFrame(method: "server", params: ["apron": .number(9), "auth": .array([.string("guest"), .string("email"), .string("external")])])]
    private var receiver: CheckedContinuation<WireFrame, any Error>?
    private(set) var authRequests = 0
    private(set) var authParams: [JSONObject] = []
    private let rejectRedirect: Bool
    init(rejectRedirect: Bool = false) { self.rejectRedirect = rejectRedirect }
    private(set) var closed = false
    private var held: WireFrame?

    func send(_ frame: WireFrame) async throws {
        guard let id = frame.id else { return }
        if frame.method == "auth" {
            authRequests += 1
            authParams.append(frame.params ?? [:])
            if rejectRedirect, frame.params?["return_url"] != nil {
                push(WireFrame(id: id, error: RPCError(code: -32602, message: "Return URL not allowed")))
                return
            }
            if frame.params?["token"] != nil {
                held = WireFrame(id: id, result: ["you": .object(["user_id": .string("ada")]), "token": .string("saved-token")])
                return
            }
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

@MainActor @Test func protocolWarningsAreOncePerServerAndVersion() {
    let server = ServerModel(ServerProfile(address: "wss://chat.example/"))
    #expect(server.protocolWarning == nil)
    server.snapshot.server = ["apron": .number(10)]
    #expect(server.protocolWarning == nil)
    server.snapshot.server = ["apron": .number(11)]
    #expect(server.protocolWarning?.contains("version 11") == true)
    #expect(server.protocolWarning?.contains("wss://chat.example/") == true)
    server.acknowledgeProtocolWarning()
    #expect(server.protocolWarning == nil)
    server.snapshot = SessionSnapshot()
    server.snapshot.server = ["apron": .number(11)]
    #expect(server.protocolWarning == nil)
    server.snapshot.server = ["apron": .number(12)]
    #expect(server.protocolWarning != nil)
    let other = ServerModel(ServerProfile(address: "wss://other.example/"))
    other.snapshot.server = ["apron": .number(11)]
    #expect(other.protocolWarning != nil)
}

@Test func browserCallbacksValidateAndExpire() throws {
    let now = Date()
    let attempt = BrowserSignIn.Attempt(now: now)
    let url = URL(string: "sidetable://signin#token=a%2Bb%3Dc&state=\(attempt.state)&server=wss%3A%2F%2Fevil.example")!
    let callback = try #require(BrowserSignIn.parse(url))
    #expect(callback.token == "a+b=c")
    #expect(attempt.matches(callback, now: now))
    #expect(!attempt.matches(callback, now: now.addingTimeInterval(BrowserSignIn.lifetime)))
    #expect(!BrowserSignIn.Attempt(now: now).matches(callback, now: now))
    for raw in ["sidetable://signin#token=secret", "sidetable://signin#state=s&token=",
                "sidetable://signin#state=s&state=s&token=t", "sidetable://signin#state=s&token=a&token=b",
                "sidetable://signin?state=s#token=t", "sidetable://signin/path#state=s&token=t",
                "sidetable://user@signin#state=s&token=t", "sidetable://signin#state=s&token=a%0Ab"] {
        #expect(BrowserSignIn.parse(URL(string: raw)!) == nil)
    }
}

@MainActor @Test func browserCallbackIsSingleUseAndBoundToCurrentProposal() async throws {
    let transport = ConnectionTransport()
    let session = ApronSession(transportFactory: { transport })
    let connection = ServerConnection(makeSession: { _, _ in session }, openURL: { _ in true })
    defer { connection.stop() }
    connection.connect(url: URL(string: "wss://example.com/")!, token: nil, seed: nil,
                       pageLimit: 5, available: { true }, receive: { _ in })
    try await waitForConnection { await session.snapshot().phase == .signIn }
    connection.requestExternalSignIn(reportError: { _ in })
    try await waitForConnection { await transport.authRequests == 1 }
    await transport.release()
    try await waitForConnection { !connection.busy }
    let old = try #require(connection.browserAttempt)
    #expect(!connection.accepts(.init(state: "wrong", token: "secret")))
    connection.requestExternalSignIn(reportError: { _ in })
    #expect(!connection.accepts(.init(state: old.state, token: "secret")))
    try await waitForConnection { await transport.authRequests == 2 }
    await transport.release()
    try await waitForConnection { !connection.busy }
    let attempt = try #require(connection.browserAttempt)
    let callback = BrowserSignIn.Callback(state: attempt.state, token: "secret")
    #expect(connection.completeBrowserSignIn(callback, reportError: { _ in }))
    #expect(!connection.completeBrowserSignIn(callback, reportError: { _ in }))
    #expect(connection.browserAttempt == nil)
    try await waitForConnection { await transport.authRequests == 3 }
    await transport.release()
    try await waitForConnection { !connection.busy }
}

@MainActor @Test func rejectedNativeRedirectFallsBackToCodeProposal() async throws {
    let transport = ConnectionTransport(rejectRedirect: true)
    let session = ApronSession(transportFactory: { transport })
    var opened = false
    let connection = ServerConnection(makeSession: { _, _ in session }, openURL: { _ in opened = true; return true })
    defer { connection.stop() }
    connection.connect(url: URL(string: "wss://example.com/")!, token: nil, seed: nil,
                       pageLimit: 5, available: { true }, receive: { _ in })
    try await waitForConnection { await session.snapshot().phase == .signIn }
    var error: String?
    connection.requestExternalSignIn(reportError: { error = $0 })
    try await waitForConnection { await transport.authRequests == 2 }
    await transport.release()
    try await waitForConnection { !connection.busy }
    let params = await transport.authParams
    #expect(params[0].string("return_url") == "sidetable://signin")
    #expect(params[0].string("state")?.isEmpty == false)
    #expect(params[1]["return_url"] == nil && params[1]["state"] == nil)
    #expect(opened && error == nil && !connection.awaitingBrowserReturn)
}

@MainActor @Test func browserReturnRoutesToOriginalServerAndNeverReviewsUnknownTokens() async throws {
    let model = AppModel(preview: true)
    let transport = ConnectionTransport()
    let session = ApronSession(transportFactory: { transport })
    let connection = ServerConnection(makeSession: { _, _ in session }, openURL: { _ in true })
    let server = ServerModel(ServerProfile(address: "wss://original.example/"), connection: connection)
    model.servers.append(server)
    defer { connection.stop() }
    connection.connect(url: URL(string: server.profile.address)!, token: nil, seed: nil,
                       pageLimit: 5, available: { true }, receive: { _ in })
    try await waitForConnection { await session.snapshot().phase == .signIn }
    connection.requestExternalSignIn(reportError: { _ in })
    try await waitForConnection { await transport.authRequests == 1 }
    await transport.release()
    try await waitForConnection { !connection.busy }
    let attempt = try #require(connection.browserAttempt)
    let callback = URL(string: "sidetable://signin#state=\(attempt.state)&token=private-token&server=wss://attacker.example/")!
    model.receiveLink(callback)
    #expect(model.selectedServer == server.id)
    #expect(!model.showOpenLink && model.openLinkText.isEmpty)
    try await waitForConnection { await transport.authRequests == 2 }
    let approval = try #require(await transport.authParams.last)
    #expect(approval.string("scheme") == "external" && approval.string("token") == "private-token")
    #expect(!model.servers.contains { $0.profile.address.contains("attacker") })
    await transport.release()
    try await waitForConnection { !connection.busy }
    #expect(await session.snapshot().you.string("user_id") == "ada")
    model.receiveLink(callback)
    #expect(model.globalError != nil && model.globalError?.contains("private-token") == false)
    #expect(!model.showOpenLink && model.openLinkText.isEmpty)
    #expect(await transport.authRequests == 2)
}
