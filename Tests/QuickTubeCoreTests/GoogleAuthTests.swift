import Foundation
import QuickTubeCore
import Testing

/// Lock-guarded clock the tests can advance.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Captures the authorization URL a sign-in would open, without navigating.
final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var value: URL? { lock.withLock { url } }

    func set(_ url: URL) { lock.withLock { self.url = url } }

    /// The loopback redirect the flow is listening on.
    var redirectURI: URL? {
        value.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    func waitUntilOpened() async throws {
        for _ in 0..<200 where value == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// True once nothing accepts connections on `url` (retries briefly while the listener winds down).
func isClosed(_ url: URL) async -> Bool {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    for _ in 0..<20 {
        do {
            _ = try await session.data(from: url)
        } catch {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

extension NetworkSuite {
    @Suite struct GoogleAuthTests {
        let store = InMemorySecretStore()
        let endpoints = OAuthEndpoints(
            authorization: URL(string: "https://auth.example/authorize")!,
            token: URL(string: "https://auth.example/token")!)

        func makeAuth(clock: TestClock = TestClock()) -> GoogleAuth {
            StubURLProtocol.reset()
            return GoogleAuth(
                store: store, session: StubURLProtocol.makeSession(), endpoints: endpoints,
                now: { clock.now })
        }

        func tokenJSON(refresh: String? = "r1", access: String = "a1", expires: Int = 3600) -> Data {
            var json =
                "{\"access_token\":\"\(access)\",\"expires_in\":\(expires),\"token_type\":\"Bearer\""
            if let refresh { json += ",\"refresh_token\":\"\(refresh)\"" }
            return Data((json + "}").utf8)
        }

        @Test func authorizationURLCarriesPKCEAndScope() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            let url = try await auth.authorizationURL(
                pkce: pkce, redirectURI: "http://127.0.0.1:4242", state: "xyz")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            #expect(url.host == "auth.example")
            #expect(value("client_id") == "cid")
            #expect(value("redirect_uri") == "http://127.0.0.1:4242")
            #expect(value("response_type") == "code")
            #expect(
                value("scope")
                    == "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/drive.file"
            )
            #expect(value("code_challenge") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            #expect(value("code_challenge_method") == "S256")
            #expect(value("state") == "xyz")
            #expect(value("access_type") == "offline")
            #expect(value("prompt") == "consent")
        }

        @Test func authorizationURLNeedsClient() async throws {
            let auth = makeAuth()
            await #expect(throws: AuthError.missingClient) {
                _ = try await auth.authorizationURL(
                    pkce: .random(), redirectURI: "http://127.0.0.1:1", state: "s")
            }
        }

        @Test func exchangeStoresRefreshTokenAndCachesAccess() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON()))
            let pkce = PKCE(verifier: "verifier-value")
            try await auth.exchange(
                code: "the-code", pkce: pkce, redirectURI: "http://127.0.0.1:4242")

            let request = StubURLProtocol.requests[0]
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(request.httpMethod == "POST")
            #expect(request.url == endpoints.token)
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code=the-code"))
            #expect(body.contains("code_verifier=verifier-value"))
            #expect(body.contains("client_secret=sec"))
            #expect(try store.get("oauth.refresh_token") == "r1")
            #expect(try await auth.isSignedIn())
            // Cached: no second request.
            #expect(try await auth.accessToken() == "a1")
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func accessTokenRefreshesWhenExpired() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            try store.set("stored-refresh", for: "oauth.refresh_token")
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON(refresh: nil, access: "fresh")))
            #expect(try await auth.accessToken() == "fresh")
            let body = String(
                decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("grant_type=refresh_token"))
            #expect(body.contains("refresh_token=stored-refresh"))
        }

        @Test func accessTokenWithoutRefreshTokenIsNotSignedIn() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            await #expect(throws: AuthError.notSignedIn) { _ = try await auth.accessToken() }
        }

        @Test func revokedTokenClearsSignIn() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            try store.set("dead", for: "oauth.refresh_token")
            StubURLProtocol.enqueue(
                .init(status: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8)))
            await #expect(throws: AuthError.tokenRevoked) { _ = try await auth.accessToken() }
            #expect(try await auth.isSignedIn() == false)
        }

        @Test func serverErrorIsBadResponse() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            try store.set("r", for: "oauth.refresh_token")
            StubURLProtocol.enqueue(.init(status: 503))
            await #expect(throws: AuthError.badResponse(503)) { _ = try await auth.accessToken() }
        }

        @Test func signOutForgetsRefreshToken() async throws {
            let auth = makeAuth()
            try store.set("r", for: "oauth.refresh_token")
            try await auth.signOut()
            #expect(try await auth.isSignedIn() == false)
        }

        @Test func cachedTokenIsReusedOutsideSkew() async throws {
            let clock = TestClock()
            let auth = makeAuth(clock: clock)
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON()))
            try await auth.exchange(code: "c", pkce: PKCE(verifier: "v"), redirectURI: "http://127.0.0.1:1")
            clock.advance(by: 3000)
            #expect(try await auth.accessToken() == "a1")
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func tokenInsideSkewIsRefreshed() async throws {
            let clock = TestClock()
            let auth = makeAuth(clock: clock)
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON()))
            try await auth.exchange(code: "c", pkce: PKCE(verifier: "v"), redirectURI: "http://127.0.0.1:1")
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON(refresh: nil, access: "a2")))
            clock.advance(by: 3550)
            #expect(try await auth.accessToken() == "a2")
            #expect(StubURLProtocol.requests.count == 2)
        }

        @Test func concurrentCallsShareOneRefresh() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            try store.set("r", for: "oauth.refresh_token")
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON(refresh: nil, access: "shared")))
            async let first = auth.accessToken()
            async let second = auth.accessToken()
            let tokens = try await [first, second]
            #expect(tokens == ["shared", "shared"])
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func cancelledSignInThrowsCancellationAndStopsServer() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            let opened = OpenedURL()
            let flow = Task { try await auth.signIn { opened.set($0) } }
            try await opened.waitUntilOpened()
            let redirect = try #require(opened.redirectURI)
            // Listening before the cancel: an unrelated request gets a 404, not a refusal.
            let (_, probe) = try await URLSession.shared.data(from: redirect)
            #expect((probe as? HTTPURLResponse)?.statusCode == 404)
            flow.cancel()
            await #expect(throws: CancellationError.self) { try await flow.value }
            #expect(await isClosed(redirect))
            #expect(try await auth.isSignedIn() == false)
        }

        @Test func signInTimesOut() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            let opened = OpenedURL()
            await #expect(throws: AuthError.timedOut) {
                try await auth.signIn(timeout: .milliseconds(100)) { opened.set($0) }
            }
            let redirect = try #require(opened.redirectURI)
            #expect(await isClosed(redirect))
        }

        @Test func exchangeWithoutRefreshTokenFails() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON(refresh: nil)))
            await #expect(throws: AuthError.badResponse(200)) {
                try await auth.exchange(
                    code: "c", pkce: PKCE(verifier: "v"), redirectURI: "http://127.0.0.1:1")
            }
            #expect(try await auth.isSignedIn() == false)
        }
    }
}
