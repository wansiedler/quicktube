import Foundation
import Network

/// Accepts exactly one HTTP request on 127.0.0.1 and hands back its query.
public actor LoopbackServer {
    public struct Callback: Sendable, Equatable {
        public let code: String?
        public let state: String?
        public let error: String?

        public init(code: String?, state: String?, error: String?) {
            self.code = code
            self.state = state
            self.error = error
        }
    }

    public enum ServerError: Error {
        case noPort
    }

    private let listener: NWListener
    private var received: Callback?
    private var failure: Error?
    private var finished = false
    private var waiter: CheckedContinuation<Callback, Error>?

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Returns the bound port once the listener is ready.
    public func start() async throws -> UInt16 {
        let listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            // Serial queue: this handler runs once to completion, then swaps itself out.
            let server = Weak(self)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        listener.stateUpdateHandler = { state in
                            if case .failed(let error) = state {
                                Task { await server.value?.fail(error) }
                            }
                        }
                        continuation.resume(returning: port)
                    } else {
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: ServerError.noPort)
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handle(connection) }
            }
            listener.start(queue: .global())
        }
    }

    public func waitForCallback() async throws -> Callback {
        try await withTaskCancellationHandler {
            if let received { return received }
            if let failure { throw failure }
            if finished { throw CancellationError() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    /// Cancels the listener and fails a pending `waitForCallback()` with `CancellationError`.
    public func stop() {
        listener.cancel()
        finish(throwing: CancellationError())
    }

    public static func parse(requestLine: String) -> Callback? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1" + parts[1])
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return Callback(code: value("code"), state: value("state"), error: value("error"))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let callback = Self.parse(requestLine: line).flatMap {
                $0.code != nil || $0.error != nil ? $0 : nil
            }
            let html =
                "<html><body style=\"font-family:-apple-system\">"
                + "QuickTube is signed in. You can close this window.</body></html>"
            let status = callback == nil ? "404 Not Found" : "200 OK"
            let body = callback == nil ? "" : html
            let response =
                "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in
                    connection.cancel()
                })
            guard let self, let callback else { return }
            Task { await self.deliver(callback) }
        }
    }

    private func deliver(_ callback: Callback) {
        guard !finished else { return }
        finished = true
        received = callback
        listener.cancel()
        waiter?.resume(returning: callback)
        waiter = nil
    }

    private func fail(_ error: Error) {
        finish(throwing: error)
    }

    private func finish(throwing error: Error) {
        guard !finished else { return }
        finished = true
        failure = error
        waiter?.resume(throwing: error)
        waiter = nil
    }
}

private struct Weak<T: AnyObject & Sendable>: Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
