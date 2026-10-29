import Foundation

/// Reads a response body in the chunks the network delivers, failing as soon as it
/// exceeds `limit`. The caller's session keeps its own delegate, so redirect policy
/// is unchanged; `validate` sees the response before any body is accepted.
enum BoundedDownload {
    static func data(for request: URLRequest, session: URLSession, limit: Int,
                     validate: @escaping @Sendable (URLResponse) throws -> Void) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        let receiver = Receiver(limit: limit, validate: validate)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver.start(task, continuation: $0) }
        } onCancel: { receiver.cancel(task) }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private let validate: @Sendable (URLResponse) throws -> Void
        private var data = Data()
        private var response: URLResponse?
        private var failure: (any Error)?
        private var cancelled = false
        private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

        init(limit: Int, validate: @escaping @Sendable (URLResponse) throws -> Void) {
            self.limit = limit; self.validate = validate
        }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
            let proceed = lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
            if proceed { task.resume() } else { continuation.resume(throwing: CancellationError()) }
        }

        func cancel(_ task: URLSessionDataTask) {
            lock.withLock { cancelled = true }
            task.cancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            do {
                try validate(response)
                lock.withLock {
                    self.response = response
                    if response.expectedContentLength > 0 { data.reserveCapacity(Int(min(response.expectedContentLength, Int64(limit)))) }
                }
                completionHandler(.allow)
            } catch {
                lock.withLock { failure = error }
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let exceeded = lock.withLock {
                guard failure == nil else { return false }
                guard data.count + chunk.count <= limit else { failure = URLError(.dataLengthExceedsMaximum); return true }
                data.append(chunk)
                return false
            }
            if exceeded { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, result): (CheckedContinuation<(Data, URLResponse), any Error>?, Result<(Data, URLResponse), any Error>) = lock.withLock {
                let result: Result<(Data, URLResponse), any Error>
                if cancelled { result = .failure(CancellationError()) }
                else if let failure { result = .failure(failure) }
                else if let error { result = .failure(error) }
                else if let response { result = .success((data, response)) }
                else { result = .failure(URLError(.badServerResponse)) }
                defer { self.continuation = nil; data = Data() }
                return (self.continuation, result)
            }
            continuation?.resume(with: result)
        }
    }
}
