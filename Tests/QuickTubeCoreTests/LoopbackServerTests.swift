import Foundation
import QuickTubeCore
import Testing

@Suite struct LoopbackServerTests {
    @Test func parsesQueryFromRequestLine() {
        let callback = LoopbackServer.parse(requestLine: "GET /?code=4%2Fabc&state=s1 HTTP/1.1")
        #expect(callback == LoopbackServer.Callback(code: "4/abc", state: "s1", error: nil))
    }

    @Test func parsesErrorAndRejectsNonGet() {
        #expect(
            LoopbackServer.parse(requestLine: "GET /?error=access_denied&state=s HTTP/1.1")?.error
                == "access_denied")
        #expect(LoopbackServer.parse(requestLine: "POST / HTTP/1.1") == nil)
        #expect(LoopbackServer.parse(requestLine: "") == nil)
    }

    @Test func receivesOneCallbackOverHTTP() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz")!
        async let callback = server.waitForCallback()
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("close this window"))
        #expect(try await callback == LoopbackServer.Callback(code: "abc", state: "xyz", error: nil))
    }

    @Test func stopWhileWaitingThrowsCancellation() async throws {
        let server = try LoopbackServer()
        _ = try await server.start()
        let waiting = Task { try await server.waitForCallback() }
        await server.stop()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func ignoresUnrelatedRequestsBeforeCallback() async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        async let callback = server.waitForCallback()
        let (_, favicon) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await callback == LoopbackServer.Callback(code: "abc", state: "xyz", error: nil))
    }
}
