import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// `HTTPStreamingTransport` over `URLSession`, delegate-based so it streams on every platform
/// (`URLSession.bytes(for:)` does not exist in swift-corelibs-foundation).
///
/// - `send` returns when the first body bytes (or the end of the response) arrive, carrying the
///   status and headers.
/// - Successful bodies stream chunk by chunk. Non-2xx bodies are collected (up to
///   `maxErrorBodyBytes`) and delivered as one chunk when complete, so providers can read the
///   error document.
/// - Cancelling the task awaiting `send`, cancelling the task iterating the body, or abandoning
///   the body stream cancels the underlying `URLSessionTask`.
public final class URLSessionStreamingTransport: HTTPStreamingTransport {
    private let session: URLSession
    private let delegate: StreamingSessionDelegate

    public init(configuration: URLSessionConfiguration = .ephemeral, maxErrorBodyBytes: Int = 64 * 1024) {
        let delegate = StreamingSessionDelegate(maxErrorBodyBytes: maxErrorBodyBytes)
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // The session retains its delegate until invalidated; running streams may finish first.
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let task = session.dataTask(with: Self.makeURLRequest(request))
        let (body, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        bodyContinuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        let delegate = self.delegate
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseHead, any Error>) in
                delegate.register(taskIdentifier: task.taskIdentifier, response: continuation, body: bodyContinuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return HTTPStreamResponse(status: head.status, headers: head.headers, body: body)
    }

    /// Maps an `HTTPRequest` to a `URLRequest`. Internal for tests.
    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers.fields {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    /// Maps a URL loading error to the engine's error vocabulary.
    static func mapError(_ error: any Error) -> any Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return ProviderError.network("The request timed out.")
            case .notConnectedToInternet, .networkConnectionLost:
                return ProviderError.network("The device is offline.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return ProviderError.network("The provider's server could not be reached.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return ProviderError.network("A secure connection to the provider could not be established.")
            default:
                return ProviderError.network("The connection failed (URL error \(urlError.code.rawValue)).")
            }
        }
        return ProviderError.network("The connection failed.")
    }
}

/// Status and headers of a response.
struct ResponseHead: Sendable {
    let status: Int
    let headers: HTTPHeaders

    init(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else {
            self.status = 0
            self.headers = [:]
            return
        }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                fields[name] = text
            }
        }
        self.status = http.statusCode
        self.headers = HTTPHeaders(fields)
    }
}

/// Routes `URLSession` delegate callbacks to the stream of the task they belong to.
///
/// All mutable state lives in a `Mutex`; continuations are resumed outside the lock.
final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct TaskState {
        var response: CheckedContinuation<ResponseHead, any Error>?
        let body: AsyncThrowingStream<Data, any Error>.Continuation
        /// Non-nil once the response turned out to be an error; collects its body.
        var errorBody: Data?
    }

    private let tasks = Mutex<[Int: TaskState]>([:])
    private let maxErrorBodyBytes: Int

    init(maxErrorBodyBytes: Int) {
        self.maxErrorBodyBytes = max(0, maxErrorBodyBytes)
    }

    func register(
        taskIdentifier: Int,
        response: CheckedContinuation<ResponseHead, any Error>,
        body: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        tasks.withLock { $0[taskIdentifier] = TaskState(response: response, body: body, errorBody: nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = maxErrorBodyBytes
        let (pendingResponse, head, forward): (CheckedContinuation<ResponseHead, any Error>?, ResponseHead?, AsyncThrowingStream<Data, any Error>.Continuation?) =
            tasks.withLock { tasks in
                guard var state = tasks[dataTask.taskIdentifier] else { return (nil, nil, nil) }
                var pending: CheckedContinuation<ResponseHead, any Error>?
                var head: ResponseHead?
                if let continuation = state.response {
                    let received = ResponseHead(dataTask.response)
                    head = received
                    pending = continuation
                    state.response = nil
                    if !(200..<300).contains(received.status) {
                        state.errorBody = Data()
                    }
                }
                if var errorBody = state.errorBody {
                    let room = max(0, limit - errorBody.count)
                    errorBody.append(data.prefix(room))
                    state.errorBody = errorBody
                    tasks[dataTask.taskIdentifier] = state
                    return (pending, head, nil)
                }
                tasks[dataTask.taskIdentifier] = state
                return (pending, head, state.body)
            }
        if let pendingResponse, let head {
            pendingResponse.resume(returning: head)
        }
        forward?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let state = tasks.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            let mapped = URLSessionStreamingTransport.mapError(error)
            state.response?.resume(throwing: mapped)
            state.body.finish(throwing: mapped)
            return
        }
        // A response without body bytes completes here without ever reaching `didReceive`.
        let head = ResponseHead(task.response)
        state.response?.resume(returning: head)
        if let errorBody = state.errorBody, !errorBody.isEmpty {
            state.body.yield(errorBody)
        }
        state.body.finish()
    }
}
