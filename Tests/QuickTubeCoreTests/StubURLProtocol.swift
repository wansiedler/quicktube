import Foundation
import Testing

/// Scripted responses for URLSession. Global state: every suite that uses it
/// must live under `NetworkSuite`, which is serialized.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [(URLRequest) -> Response] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.withLock {
            handlers = []
            recorded = []
        }
    }

    static func enqueue(_ response: Response) {
        enqueue { _ in response }
    }

    static func enqueue(_ handler: @escaping (URLRequest) -> Response) {
        lock.withLock { handlers.append(handler) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        // URLSession moves the body into a stream before the protocol sees it.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Data(reading: stream)
        }
        let handler: ((URLRequest) -> Response)? = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handlers.isEmpty ? nil : Self.handlers.removeFirst()
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            append(buffer, count: count)
        }
    }
}

/// Parent for every suite that scripts StubURLProtocol; `.serialized` is inherited.
@Suite(.serialized) struct NetworkSuite {}
