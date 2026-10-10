import Foundation

public struct OAuthClient: Sendable, Equatable {
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }
}

public struct OAuthEndpoints: Sendable {
    public let authorization: URL
    public let token: URL

    public init(authorization: URL, token: URL) {
        self.authorization = authorization
        self.token = token
    }

    public static let google = OAuthEndpoints(
        authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!)
}

public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
}

public enum AuthError: Error, Equatable {
    case missingClient
    case notSignedIn
    case tokenRevoked
    case cancelled
    case timedOut
    case badCallback
    case badResponse(Int)
}

/// OAuth 2.0 for installed apps: PKCE, loopback redirect, refresh token in the store.
public actor GoogleAuth: TokenProvider {
    public static let scopes = [
        "https://www.googleapis.com/auth/youtube.upload",
        "https://www.googleapis.com/auth/drive.file",
    ]
    public static let scope = scopes.joined(separator: " ")

    enum Key {
        static let clientID = "oauth.client_id"
        static let clientSecret = "oauth.client_secret"
        static let refreshToken = "oauth.refresh_token"
    }

    private let store: SecretStore
    private let session: URLSession
    private let endpoints: OAuthEndpoints
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiry: Date)?
    private var refreshing: Task<String, Error>?

    public init(
        store: SecretStore,
        session: URLSession = .shared,
        endpoints: OAuthEndpoints = .google,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.session = session
        self.endpoints = endpoints
        self.now = now
    }

    public func client() throws -> OAuthClient? {
        guard let id = try store.get(Key.clientID), let secret = try store.get(Key.clientSecret) else {
            return nil
        }
        return OAuthClient(id: id, secret: secret)
    }

    public func setClient(_ client: OAuthClient) throws {
        try store.set(client.id, for: Key.clientID)
        try store.set(client.secret, for: Key.clientSecret)
    }

    public func isSignedIn() throws -> Bool {
        try store.get(Key.refreshToken) != nil
    }

    public func signOut() throws {
        try store.delete(Key.refreshToken)
        cached = nil
    }

    /// Full installed-app flow: loopback listener, browser, code exchange.
    /// Gives up with `AuthError.timedOut` after `timeout`; cancelling the calling task
    /// throws `CancellationError`. The listener is stopped before this returns either way.
    public func signIn(
        timeout: Duration = .seconds(300),
        openBrowser: @escaping @Sendable (URL) -> Void
    ) async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        do {
            let redirectURI = "http://127.0.0.1:\(port)"
            let pkce = PKCE.random()
            let state = UUID().uuidString
            openBrowser(try authorizationURL(pkce: pkce, redirectURI: redirectURI, state: state))
            let callback = try await Self.callback(from: server, timeout: timeout)
            await server.stop()
            guard callback.error == nil else { throw AuthError.cancelled }
            guard callback.state == state, let code = callback.code else { throw AuthError.badCallback }
            try await exchange(code: code, pkce: pkce, redirectURI: redirectURI)
        } catch {
            await server.stop()
            throw error
        }
    }

    /// Races the browser callback against `timeout`.
    private static func callback(
        from server: LoopbackServer, timeout: Duration
    ) async throws -> LoopbackServer.Callback {
        try await withThrowingTaskGroup(of: LoopbackServer.Callback?.self) { group in
            group.addTask { try await server.waitForCallback() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let callback = first else {
                throw AuthError.timedOut
            }
            return callback
        }
    }

    public func authorizationURL(pkce: PKCE, redirectURI: String, state: String) throws -> URL {
        guard let client = try client() else { throw AuthError.missingClient }
        var components = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: String) async throws {
        guard let client = try client() else { throw AuthError.missingClient }
        let token = try await tokenRequest([
            "code": code,
            "client_id": client.id,
            "client_secret": client.secret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ])
        guard let refresh = token.refreshToken else { throw AuthError.badResponse(200) }
        try store.set(refresh, for: Key.refreshToken)
        cached = (token.accessToken, now().addingTimeInterval(token.expiresIn))
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiry.timeIntervalSince(now()) > 60 {
            return cached.token
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await refreshAccessToken() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refreshAccessToken() async throws -> String {
        guard let client = try client() else { throw AuthError.missingClient }
        guard let refresh = try store.get(Key.refreshToken) else { throw AuthError.notSignedIn }
        let token = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": client.id,
            "client_secret": client.secret,
        ])
        cached = (token.accessToken, now().addingTimeInterval(token.expiresIn))
        return token.accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if status == 400, error?.error == "invalid_grant" {
                try? store.delete(Key.refreshToken)
                cached = nil
                throw AuthError.tokenRevoked
            }
            throw AuthError.badResponse(status)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TokenResponse.self, from: data)
    }
}

func formEncode(_ form: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return form.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .joined(separator: "&")
}
