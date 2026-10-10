import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct GoogleAuthTests {
        let store = InMemorySecretStore()
        let endpoints = OAuthEndpoints(
            authorization: URL(string: "https://auth.example/authorize")!,
            token: URL(string: "https://auth.example/token")!)

        func makeAuth(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> GoogleAuth {
            StubURLProtocol.reset()
            return GoogleAuth(
                store: store, session: StubURLProtocol.makeSession(), endpoints: endpoints,
                now: { now })
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
            #expect(value("scope") == "https://www.googleapis.com/auth/youtube.upload")
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
    }
}
