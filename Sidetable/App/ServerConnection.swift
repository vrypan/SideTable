import AppKit
import Observation
import ApronCore

/// Owns one server's live session and sign-in operations. Application policy is
/// supplied through callbacks; this object does not own profiles or cached views.
@MainActor @Observable
final class ServerConnection {
    private(set) var busy = false
    @ObservationIgnored var session: ApronSession? {
        didSet { if oldValue !== session { browserAttempt = nil } }
    }
    private(set) var browserAttempt: BrowserSignIn.Attempt?
    var awaitingBrowserReturn: Bool { browserAttempt != nil }
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var authenticationOperation = UUID()
    private let makeSession: (URL, String?) -> ApronSession
    private let openURL: (URL) -> Bool

    init(makeSession: @escaping (URL, String?) -> ApronSession = { ApronSession(url: $0, token: $1) },
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.makeSession = makeSession
        self.openURL = openURL
    }

    deinit {
        listener?.cancel()
        let session = session
        Task { await session?.stop() }
    }

    func connect(url: URL, token: String?, seed: HistorySeed?, pageLimit: Int,
                 available: @escaping () -> Bool, diagnostics: (@Sendable (SessionDiagnostic) -> Void)? = nil, receive: @escaping (SessionEvent) -> Void) {
        let old = session
        authenticationOperation = UUID()
        busy = false
        listener?.cancel()
        let session = makeSession(url, token)
        self.session = session
        listener = Task { [weak self] in
            await old?.stop()
            guard !Task.isCancelled else { await session.stop(); return }
            await session.setDiagnostics(diagnostics)
            await session.setRecoveryPageLimit(pageLimit)
            if let seed { await session.restore(seed) }
            await session.setConnectionAvailable(available())
            guard !Task.isCancelled else { await session.stop(); return }
            await session.start()
            guard !Task.isCancelled else { await session.stop(); return }
            for await event in session.events {
                guard !Task.isCancelled else { break }
                if case .snapshot(let snapshot) = event, !snapshot.you.isEmpty {
                    self?.browserAttempt = nil
                }
                receive(event)
            }
        }
    }

    func stop() {
        authenticationOperation = UUID()
        busy = false
        browserAttempt = nil
        listener?.cancel()
        let old = session
        Task { await old?.stop() }
    }

    func signIn(scheme: String, fields: JSONObject, reportError: @escaping (String?) -> Void) {
        authenticate(reportError: reportError) { session, _ in
            try await session.authenticate(scheme: scheme, fields: fields)
        }
    }

    func requestEmail(_ email: String, reportError: @escaping (String?) -> Void) {
        authenticate(reportError: reportError) { session, _ in
            try await session.requestEmail(email)
        }
    }

    func requestExternalSignIn(useRedirect: Bool = true, reportError: @escaping (String?) -> Void) {
        authenticate(reportError: reportError) { session, operation in
            let attempt = useRedirect ? BrowserSignIn.Attempt() : nil
            let url: URL
            do {
                url = try await session.requestExternalSignIn(
                    returnURL: attempt == nil ? nil : BrowserSignIn.returnURL, state: attempt?.state)
            } catch let error as RPCError where useRedirect && error.retryAfter == nil && [-32602, -32601, -32001].contains(error.code) {
                // A server may support browser codes but not allow native return URLs.
                guard self.authenticationOperation == operation else { return }
                let codeURL = try await session.requestExternalSignIn()
                guard self.authenticationOperation == operation, self.session === session else { return }
                if !self.openURL(codeURL) {
                    reportError("The sign-in page could not be opened. Check your default browser and try again.")
                }
                return
            }
            guard self.authenticationOperation == operation, self.session === session,
                  await session.snapshot().pendingSignIn == "external" else { return }
            self.browserAttempt = attempt
            if !self.openURL(url) {
                self.browserAttempt = nil
                reportError("The sign-in page could not be opened. Check your default browser and try again.")
            }
        }
    }

    func accepts(_ callback: BrowserSignIn.Callback) -> Bool {
        !busy && session != nil && browserAttempt?.matches(callback) == true
    }

    @discardableResult
    func completeBrowserSignIn(_ callback: BrowserSignIn.Callback, reportError: @escaping (String?) -> Void) -> Bool {
        guard accepts(callback) else { return false }
        // authenticate consumes the state synchronously, before any suspension.
        authenticate(reportError: reportError) { session, _ in
            guard await session.snapshot().you.isEmpty else { return }
            try await session.authenticate(scheme: "external", fields: ["token": .string(callback.token)])
        }
        return true
    }

    private func authenticate(reportError: @escaping (String?) -> Void,
                              action: @escaping (ApronSession, UUID) async throws -> Void) {
        guard let session, !busy else { return }
        browserAttempt = nil
        let operation = UUID()
        authenticationOperation = operation
        busy = true
        reportError(nil)
        Task {
            defer { if authenticationOperation == operation { busy = false } }
            do { try await action(session, operation) }
            catch {
                guard authenticationOperation == operation else { return }
                reportError(error.localizedDescription)
            }
        }
    }
}
