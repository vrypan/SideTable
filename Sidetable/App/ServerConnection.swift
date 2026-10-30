import AppKit
import Observation
import ApronCore

/// Owns one server's live session and sign-in operations. Application policy is
/// supplied through callbacks; this object does not own profiles or cached views.
@MainActor @Observable
final class ServerConnection {
    private(set) var busy = false
    @ObservationIgnored var session: ApronSession?
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
                 available: @escaping () -> Bool, receive: @escaping (SessionEvent) -> Void) {
        let old = session
        authenticationOperation = UUID()
        busy = false
        listener?.cancel()
        let session = makeSession(url, token)
        self.session = session
        listener = Task {
            await old?.stop()
            guard !Task.isCancelled else { await session.stop(); return }
            await session.setRecoveryPageLimit(pageLimit)
            if let seed { await session.restore(seed) }
            await session.setConnectionAvailable(available())
            guard !Task.isCancelled else { await session.stop(); return }
            await session.start()
            guard !Task.isCancelled else { await session.stop(); return }
            for await event in session.events {
                guard !Task.isCancelled else { break }
                receive(event)
            }
        }
    }

    func stop() {
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

    func requestExternalSignIn(reportError: @escaping (String?) -> Void) {
        authenticate(reportError: reportError) { session, operation in
            let url = try await session.requestExternalSignIn()
            guard self.authenticationOperation == operation, self.session === session,
                  await session.snapshot().pendingSignIn == "external" else { return }
            if !self.openURL(url) {
                reportError("The sign-in page could not be opened. Check your default browser and try again.")
            }
        }
    }

    private func authenticate(reportError: @escaping (String?) -> Void,
                              action: @escaping (ApronSession, UUID) async throws -> Void) {
        guard let session, !busy else { return }
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
