# QuickTube v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar app that records the screen on a global hotkey, uploads the file to YouTube as unlisted, and copies the share link.

**Architecture:** `QuickTubeCore` (library) holds every piece of logic behind a protocol: `ScreenRecorder`, `TokenProvider`, `VideoUploader`, `SecretStore`, `Notifier`. `AppState` is a `@MainActor` state machine wired to those protocols, so it is unit-tested with fakes. The `QuickTube` executable target adds the menu bar UI, the Carbon hotkey, clipboard, notifications and the concrete wiring.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI `MenuBarExtra`, ScreenCaptureKit (`SCRecordingOutput`), `URLSession`, `Network` (`NWListener`), Security (Keychain), Carbon (`RegisterEventHotKey`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-03-quicktube-design.md`

## Global Constraints

- Minimum macOS 15; `platforms: [.macOS(.v15)]` in `Package.swift`.
- Swift 6 language mode (tools version 6.0); strict concurrency must compile clean.
- No third-party packages.
- OAuth scope is exactly `https://www.googleapis.com/auth/youtube.upload`.
- Uploads request `privacyStatus = unlisted`, `selfDeclaredMadeForKids = false`; title = recording timestamp.
- Recordings live in `~/Movies/QuickTube/<yyyy-MM-dd HH.mm.ss>.mp4` and are never deleted automatically.
- Default hotkey `⌃⌥⌘R`.
- Commit author is `wansiedler <apwansiedler@gmail.com>`; no attribution trailers. Work on branch `feature/v1`.
- Before every commit: `swift test` green, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests` clean.

## File structure

```
Package.swift                                 modify: add executable target
Makefile                                      create: build, app, install, test
Sources/QuickTubeCore/
  ShareLink.swift                             exists
  PKCE.swift                                  verifier/challenge (RFC 7636)
  SecretStore.swift                           protocol + InMemorySecretStore + KeychainStore
  RecordingNaming.swift                       timestamp title / file name
  GoogleAuth.swift                            OAuth client, token exchange/refresh, sign-in flow
  LoopbackServer.swift                        one-shot HTTP listener for the OAuth redirect
  YouTubeUploader.swift                       resumable videos.insert
  Recorder.swift                              ScreenCaptureKit recorder
  AppState.swift                              state machine + Notifier protocol
Sources/QuickTube/
  Info.plist
  QuickTubeApp.swift                          @main, MenuBarExtra + Settings scenes
  AppModel.swift                              wiring, settings persistence, auth actions
  HotkeyManager.swift                         Carbon global hotkey + Combo
  AppNotifier.swift                           clipboard + UNUserNotification
  MenuContent.swift
  SettingsView.swift
Tests/QuickTubeCoreTests/
  ShareLinkTests.swift                        exists
  PKCETests.swift
  SecretStoreTests.swift
  RecordingNamingTests.swift
  StubURLProtocol.swift                       URLSession stub shared by network tests
  GoogleAuthTests.swift
  LoopbackServerTests.swift
  YouTubeUploaderTests.swift
  AppStateTests.swift
README.md                                     create: setup (Google Cloud), build, install
.github/workflows/ci.yml                      modify: coverage floors
```

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd ~/IdeaProjects/NAVFLEX/quicktube
git checkout -b feature/v1 main
```

---

### Task 1: PKCE

**Files:**
- Create: `Sources/QuickTubeCore/PKCE.swift`
- Test: `Tests/QuickTubeCoreTests/PKCETests.swift`

**Interfaces:**
- Produces: `struct PKCE { let verifier: String; let challenge: String; init(verifier:); static func random() -> PKCE }`, `Data.base64URLEncodedString()`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import QuickTubeCore
import Testing

@Suite struct PKCETests {
    // RFC 7636 appendix B vector.
    @Test func challengeIsSHA256Base64URL() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierIsURLSafeAndLongEnough() {
        let pkce = PKCE.random()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.count == 43)
        #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(PKCE.random().verifier != pkce.verifier)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PKCETests`
Expected: compile error, `PKCE` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import CryptoKit
import Foundation

/// RFC 7636 code verifier and S256 challenge.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func random() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    /// Base64 with the URL-safe alphabet and no padding, as OAuth expects.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PKCETests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/PKCE.swift Tests/QuickTubeCoreTests/PKCETests.swift
git commit -m "Add PKCE verifier and challenge"
```

---

### Task 2: SecretStore

**Files:**
- Create: `Sources/QuickTubeCore/SecretStore.swift`
- Test: `Tests/QuickTubeCoreTests/SecretStoreTests.swift`

**Interfaces:**
- Produces: `protocol SecretStore: Sendable { get(_:) throws -> String?; set(_:for:) throws; delete(_:) throws }`, `InMemorySecretStore`, `KeychainStore(service:)`, `KeychainError(status:)`.

- [ ] **Step 1: Write the failing test**

```swift
import QuickTubeCore
import Testing

@Suite struct SecretStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(try store.get("k") == nil)
        try store.set("v1", for: "k")
        #expect(try store.get("k") == "v1")
        try store.set("v2", for: "k")
        #expect(try store.get("k") == "v2")
        try store.delete("k")
        #expect(try store.get("k") == nil)
        try store.delete("k")  // deleting a missing key is not an error
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SecretStoreTests`
Expected: compile error.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

/// Test double and fallback; nothing persists.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String, for key: String) throws {
        lock.withLock { values[key] = value }
    }

    public func delete(_ key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items under one service name.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.wansiedler.quicktube") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func get(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var query = query(key)
            query[kSecValueData as String] = data
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SecretStoreTests`
Expected: pass. `KeychainStore` is exercised manually in Task 10 (it needs a signed bundle to behave).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/SecretStore.swift Tests/QuickTubeCoreTests/SecretStoreTests.swift
git commit -m "Add SecretStore with in-memory and Keychain backends"
```

---

### Task 3: RecordingNaming

**Files:**
- Create: `Sources/QuickTubeCore/RecordingNaming.swift`
- Test: `Tests/QuickTubeCoreTests/RecordingNamingTests.swift`

**Interfaces:**
- Produces: `RecordingNaming.title(for: Date, timeZone: TimeZone = .current) -> String`, `RecordingNaming.fileName(for:timeZone:) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import QuickTubeCore
import Testing

@Suite struct RecordingNamingTests {
    let date = Date(timeIntervalSince1970: 1_791_624_600)  // 2026-10-10 09:30:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func titleIsSortableTimestamp() {
        #expect(RecordingNaming.title(for: date, timeZone: utc) == "2026-10-10 09.30.00")
    }

    @Test func fileNameAddsExtension() {
        #expect(RecordingNaming.fileName(for: date, timeZone: utc) == "2026-10-10 09.30.00.mp4")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingNamingTests`
Expected: compile error.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One timestamp names both the file and the YouTube title.
public enum RecordingNaming {
    public static func title(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        title(for: date, timeZone: timeZone) + ".mp4"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingNamingTests`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/RecordingNaming.swift Tests/QuickTubeCoreTests/RecordingNamingTests.swift
git commit -m "Add RecordingNaming"
```

---

### Task 4: URLSession stub

**Files:**
- Create: `Tests/QuickTubeCoreTests/StubURLProtocol.swift`

**Interfaces:**
- Produces: `StubURLProtocol.makeSession() -> URLSession`, `StubURLProtocol.reset()`, `StubURLProtocol.enqueue(Response)`, `StubURLProtocol.enqueue((URLRequest) -> Response)`, `StubURLProtocol.requests: [URLRequest]` (bodies restored into `httpBody`). Network suites must be `@Suite(.serialized)` and nested under `NetworkSuite` because the queue is global.

- [ ] **Step 1: Write the stub**

```swift
import Foundation

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
```

- [ ] **Step 2: Build the tests**

Run: `swift build --build-tests`
Expected: builds (`Testing` import needed for `@Suite`; add `import Testing` at the top of the file).

- [ ] **Step 3: Commit**

```bash
git add Tests/QuickTubeCoreTests/StubURLProtocol.swift
git commit -m "Add URLSession stub for network tests"
```

---

### Task 5: GoogleAuth (tokens)

**Files:**
- Create: `Sources/QuickTubeCore/GoogleAuth.swift`
- Test: `Tests/QuickTubeCoreTests/GoogleAuthTests.swift`

**Interfaces:**
- Consumes: `PKCE`, `SecretStore`, `StubURLProtocol`.
- Produces:
  - `struct OAuthClient: Sendable, Equatable { id, secret }`
  - `struct OAuthEndpoints: Sendable { authorization: URL; token: URL; static let google }`
  - `protocol TokenProvider: Sendable { func accessToken() async throws -> String }`
  - `enum AuthError: Error, Equatable { missingClient, notSignedIn, tokenRevoked, cancelled, badCallback, badResponse(Int) }`
  - `actor GoogleAuth: TokenProvider` with `init(store:session:endpoints:now:)`, `client() throws -> OAuthClient?`, `setClient(_:) throws`, `isSignedIn() throws -> Bool`, `signOut() throws`, `authorizationURL(pkce:redirectURI:state:) throws -> URL`, `exchange(code:pkce:redirectURI:) async throws`, `accessToken() async throws -> String`.
  - `func formEncode(_: [String: String]) -> String` (internal).

- [ ] **Step 1: Write the failing test**

```swift
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
            return GoogleAuth(store: store, session: StubURLProtocol.makeSession(), endpoints: endpoints, now: { now })
        }

        func tokenJSON(refresh: String? = "r1", access: String = "a1", expires: Int = 3600) -> Data {
            var json = "{\"access_token\":\"\(access)\",\"expires_in\":\(expires),\"token_type\":\"Bearer\""
            if let refresh { json += ",\"refresh_token\":\"\(refresh)\"" }
            return Data((json + "}").utf8)
        }

        @Test func authorizationURLCarriesPKCEAndScope() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            let url = try await auth.authorizationURL(pkce: pkce, redirectURI: "http://127.0.0.1:4242", state: "xyz")
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
                _ = try await auth.authorizationURL(pkce: .random(), redirectURI: "http://127.0.0.1:1", state: "s")
            }
        }

        @Test func exchangeStoresRefreshTokenAndCachesAccess() async throws {
            let auth = makeAuth()
            try await auth.setClient(OAuthClient(id: "cid", secret: "sec"))
            StubURLProtocol.enqueue(.init(status: 200, body: tokenJSON()))
            let pkce = PKCE(verifier: "verifier-value")
            try await auth.exchange(code: "the-code", pkce: pkce, redirectURI: "http://127.0.0.1:4242")

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
            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
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
            StubURLProtocol.enqueue(.init(status: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8)))
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GoogleAuthTests`
Expected: compile error.

- [ ] **Step 3: Write minimal implementation**

```swift
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
    case badCallback
    case badResponse(Int)
}

/// OAuth 2.0 for installed apps: PKCE, loopback redirect, refresh token in the store.
public actor GoogleAuth: TokenProvider {
    public static let scope = "https://www.googleapis.com/auth/youtube.upload"

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GoogleAuthTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/GoogleAuth.swift Tests/QuickTubeCoreTests/GoogleAuthTests.swift
git commit -m "Add GoogleAuth token exchange and refresh"
```

---

### Task 6: LoopbackServer and sign-in flow

**Files:**
- Create: `Sources/QuickTubeCore/LoopbackServer.swift`
- Modify: `Sources/QuickTubeCore/GoogleAuth.swift` (add `signIn(openBrowser:)`)
- Test: `Tests/QuickTubeCoreTests/LoopbackServerTests.swift`

**Interfaces:**
- Produces: `actor LoopbackServer { struct Callback: Sendable, Equatable { code, state, error: String? }; init() throws; func start() async throws -> UInt16; func waitForCallback() async throws -> Callback; static func parse(requestLine:) -> Callback? }`, `GoogleAuth.signIn(openBrowser: @escaping @Sendable (URL) -> Void) async throws`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import QuickTubeCore
import Testing

@Suite struct LoopbackServerTests {
    @Test func parsesQueryFromRequestLine() {
        let callback = LoopbackServer.parse(requestLine: "GET /?code=4%2Fabc&state=s1 HTTP/1.1")
        #expect(callback == LoopbackServer.Callback(code: "4/abc", state: "s1", error: nil))
    }

    @Test func parsesErrorAndRejectsNonGet() {
        #expect(LoopbackServer.parse(requestLine: "GET /?error=access_denied&state=s HTTP/1.1")?.error == "access_denied")
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LoopbackServerTests`
Expected: compile error.

- [ ] **Step 3: Write the server**

```swift
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

    nonisolated(unsafe) private let listener: NWListener
    private var started = false
    private var received: Callback?
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
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: ServerError.noPort)
                    }
                    listener.stateUpdateHandler = nil
                case .failed(let error):
                    continuation.resume(throwing: error)
                    listener.stateUpdateHandler = nil
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
        if let received { return received }
        return try await withCheckedThrowingContinuation { waiter = $0 }
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
            let callback = Self.parse(requestLine: line)
            let html = "<html><body style=\"font-family:-apple-system\">QuickTube is signed in. You can close this window.</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            guard let self, let callback else { return }
            Task { await self.deliver(callback) }
        }
    }

    private func deliver(_ callback: Callback) {
        guard received == nil else { return }
        received = callback
        listener.cancel()
        waiter?.resume(returning: callback)
        waiter = nil
    }
}
```

- [ ] **Step 4: Add `signIn` to `GoogleAuth`** (inside the actor, after `signOut`)

```swift
    /// Full installed-app flow: loopback listener, browser, code exchange.
    public func signIn(openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        let server = try LoopbackServer()
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let pkce = PKCE.random()
        let state = UUID().uuidString
        openBrowser(try authorizationURL(pkce: pkce, redirectURI: redirectURI, state: state))
        let callback = try await server.waitForCallback()
        guard callback.error == nil else { throw AuthError.cancelled }
        guard callback.state == state, let code = callback.code else { throw AuthError.badCallback }
        try await exchange(code: code, pkce: pkce, redirectURI: redirectURI)
    }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter LoopbackServerTests`
Expected: 3 tests pass. If `receivesOneCallbackOverHTTP` hangs, the listener never reached `.ready`; check that `requiredLocalEndpoint` uses `"127.0.0.1"` and that the test is not sandboxed away from loopback.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuickTubeCore/LoopbackServer.swift Sources/QuickTubeCore/GoogleAuth.swift Tests/QuickTubeCoreTests/LoopbackServerTests.swift
git commit -m "Add loopback redirect server and sign-in flow"
```

---

### Task 7: YouTubeUploader

**Files:**
- Create: `Sources/QuickTubeCore/YouTubeUploader.swift`
- Test: `Tests/QuickTubeCoreTests/YouTubeUploaderTests.swift`

**Interfaces:**
- Consumes: `TokenProvider`, `StubURLProtocol`.
- Produces: `struct UploadResult: Sendable, Equatable { videoID: String; privacyStatus: String; isUnlisted: Bool }`, `enum UploadError: Error, Equatable { fileUnreadable, missingSessionURL, quotaExceeded, exhaustedRetries, badResponse(Int) }`, `protocol VideoUploader: Sendable { func upload(file: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult }`, `actor YouTubeUploader: VideoUploader` with `init(tokens:session:chunkSize:maxAttempts:sleep:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import QuickTubeCore
import Testing

struct FixedTokens: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

extension NetworkSuite {
    @Suite struct YouTubeUploaderTests {
        let sessionURL = "https://upload.example/session?upload_id=1"
        let done = Data("{\"id\":\"vid123\",\"status\":{\"privacyStatus\":\"unlisted\"}}".utf8)

        func makeFile(bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "qt-\(UUID().uuidString).mp4")
            try Data(repeating: 0xAB, count: bytes).write(to: url)
            return url
        }

        func makeUploader(chunkSize: Int = 4, maxAttempts: Int = 3) -> YouTubeUploader {
            StubURLProtocol.reset()
            return YouTubeUploader(
                tokens: FixedTokens(), session: StubURLProtocol.makeSession(),
                chunkSize: chunkSize, maxAttempts: maxAttempts, sleep: { _ in })
        }

        @Test func createsSessionThenUploadsInChunks() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-3"]))
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-7"]))
            StubURLProtocol.enqueue(.init(status: 200, body: done))

            let progress = ProgressLog()
            let result = try await uploader.upload(file: file, title: "T") { progress.add($0) }

            #expect(result == UploadResult(videoID: "vid123", privacyStatus: "unlisted"))
            #expect(result.isUnlisted)
            let requests = StubURLProtocol.requests
            #expect(requests.count == 4)
            let create = requests[0]
            #expect(create.httpMethod == "POST")
            #expect(create.url?.absoluteString.contains("uploadType=resumable") == true)
            #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            #expect(create.value(forHTTPHeaderField: "X-Upload-Content-Length") == "10")
            let metadata = try JSONSerialization.jsonObject(with: create.httpBody!) as! [String: Any]
            #expect((metadata["snippet"] as? [String: Any])?["title"] as? String == "T")
            #expect((metadata["status"] as? [String: Any])?["privacyStatus"] as? String == "unlisted")
            #expect((metadata["status"] as? [String: Any])?["selfDeclaredMadeForKids"] as? Bool == false)
            #expect(requests[1].value(forHTTPHeaderField: "Content-Range") == "bytes 0-3/10")
            #expect(requests[1].httpBody?.count == 4)
            #expect(requests[2].value(forHTTPHeaderField: "Content-Range") == "bytes 4-7/10")
            #expect(requests[3].value(forHTTPHeaderField: "Content-Range") == "bytes 8-9/10")
            #expect(requests[3].httpBody?.count == 2)
            #expect(progress.values == [0.4, 0.8, 1.0])
        }

        @Test func resumesFromServerOffsetAfterNetworkError() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 8)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-3"]))
            StubURLProtocol.enqueue { _ in StubURLProtocol.Response(status: 500) }  // chunk 2 fails
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-5"]))  // status query: 6 bytes landed
            StubURLProtocol.enqueue(.init(status: 201, body: done))

            _ = try await uploader.upload(file: file, title: "T") { _ in }

            let requests = StubURLProtocol.requests
            #expect(requests.count == 5)
            #expect(requests[3].value(forHTTPHeaderField: "Content-Range") == "bytes */8")
            #expect(requests[3].httpBody?.isEmpty ?? true)
            #expect(requests[4].value(forHTTPHeaderField: "Content-Range") == "bytes 6-7/8")
        }

        @Test func statusQueryMayReportCompletion() async throws {
            let uploader = makeUploader(chunkSize: 8)
            let file = try makeFile(bytes: 8)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(.init(status: 503))
            StubURLProtocol.enqueue(.init(status: 200, body: done))  // the query says: already done
            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.videoID == "vid123")
        }

        @Test func givesUpAfterMaxAttempts() async throws {
            let uploader = makeUploader(chunkSize: 8, maxAttempts: 2)
            let file = try makeFile(bytes: 8)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(.init(status: 500))
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-3"]))
            StubURLProtocol.enqueue(.init(status: 500))
            await #expect(throws: UploadError.exhaustedRetries) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func quotaExceededIsReported() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 2)
            let body = Data("{\"error\":{\"errors\":[{\"reason\":\"quotaExceeded\"}]}}".utf8)
            StubURLProtocol.enqueue(.init(status: 403, body: body))
            await #expect(throws: UploadError.quotaExceeded) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func missingLocationIsAnError() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 2)
            StubURLProtocol.enqueue(.init(status: 200))
            await #expect(throws: UploadError.missingSessionURL) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func unreadableFileIsAnError() async throws {
            let uploader = makeUploader()
            await #expect(throws: UploadError.fileUnreadable) {
                _ = try await uploader.upload(file: URL(fileURLWithPath: "/nonexistent/x.mp4"), title: "T") { _ in }
            }
        }

        @Test func privateStatusIsSurfaced() async throws {
            let uploader = makeUploader(chunkSize: 8)
            let file = try makeFile(bytes: 2)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"id\":\"v\",\"status\":{\"privacyStatus\":\"private\"}}".utf8)))
            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.isUnlisted == false)
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter YouTubeUploaderTests`
Expected: compile error.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct UploadResult: Sendable, Equatable {
    public let videoID: String
    public let privacyStatus: String

    public init(videoID: String, privacyStatus: String) {
        self.videoID = videoID
        self.privacyStatus = privacyStatus
    }

    /// False means YouTube overrode the request, usually the unverified-API-project lock.
    public var isUnlisted: Bool { privacyStatus == "unlisted" }
}

public enum UploadError: Error, Equatable {
    case fileUnreadable
    case missingSessionURL
    case quotaExceeded
    case exhaustedRetries
    case badResponse(Int)
}

public protocol VideoUploader: Sendable {
    func upload(file: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult
}

/// Resumable `videos.insert`: one session, fixed-size chunks, resume on failure.
public actor YouTubeUploader: VideoUploader {
    public static let endpoint = URL(
        string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!

    private let tokens: TokenProvider
    private let session: URLSession
    private let chunkSize: Int
    private let maxAttempts: Int
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        tokens: TokenProvider,
        session: URLSession = .shared,
        chunkSize: Int = 8 << 20,
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.tokens = tokens
        self.session = session
        self.chunkSize = chunkSize
        self.maxAttempts = maxAttempts
        self.sleep = sleep
    }

    public func upload(
        file: URL, title: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch {
            throw UploadError.fileUnreadable
        }
        let size = data.count
        guard size > 0 else { throw UploadError.fileUnreadable }
        let sessionURL = try await createSession(title: title, size: size)

        var offset = 0
        var attempt = 0
        while true {
            let end = min(offset + chunkSize, size)
            var request = try await authorized(URLRequest(url: sessionURL))
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(end - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            do {
                let (body, response) = try await session.upload(for: request, from: data.subdata(in: offset..<end))
                let http = try Self.http(response)
                switch http.statusCode {
                case 308:
                    offset = Self.nextOffset(rangeHeader: http.value(forHTTPHeaderField: "Range"), fallback: end)
                    attempt = 0
                    progress(Double(offset) / Double(size))
                case 200, 201:
                    progress(1)
                    return try Self.parseResult(body)
                case 500...599:
                    throw Retry()
                default:
                    throw Self.error(status: http.statusCode, body: body)
                }
            } catch let error where error is Retry || error is URLError {
                attempt += 1
                guard attempt < maxAttempts else { throw UploadError.exhaustedRetries }
                try await sleep(.seconds(1 << attempt))
                switch try await queryStatus(sessionURL, size: size) {
                case .resume(let committed):
                    offset = committed
                case .completed(let result):
                    progress(1)
                    return result
                }
            }
        }
    }

    // MARK: - Session

    private struct Metadata: Encodable {
        struct Snippet: Encodable {
            let title: String
        }
        struct Status: Encodable {
            let privacyStatus: String
            let selfDeclaredMadeForKids: Bool
        }
        let snippet: Snippet
        let status: Status
    }

    private func createSession(title: String, size: Int) async throws -> URL {
        var request = try await authorized(URLRequest(url: Self.endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONEncoder().encode(
            Metadata(
                snippet: .init(title: title),
                status: .init(privacyStatus: "unlisted", selfDeclaredMadeForKids: false)))
        let (body, response) = try await session.data(for: request)
        let http = try Self.http(response)
        guard http.statusCode == 200 else { throw Self.error(status: http.statusCode, body: body) }
        guard let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw UploadError.missingSessionURL
        }
        return url
    }

    private enum SessionStatus {
        case resume(Int)
        case completed(UploadResult)
    }

    /// `Content-Range: bytes */size` asks the server how much it has.
    private func queryStatus(_ sessionURL: URL, size: Int) async throws -> SessionStatus {
        var request = try await authorized(URLRequest(url: sessionURL))
        request.httpMethod = "PUT"
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        let (body, response) = try await session.upload(for: request, from: Data())
        let http = try Self.http(response)
        switch http.statusCode {
        case 308:
            return .resume(Self.nextOffset(rangeHeader: http.value(forHTTPHeaderField: "Range"), fallback: 0))
        case 200, 201:
            return .completed(try Self.parseResult(body))
        default:
            throw Self.error(status: http.statusCode, body: body)
        }
    }

    // MARK: - Helpers

    private struct Retry: Error {}

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw UploadError.badResponse(0) }
        return http
    }

    /// `Range: bytes=0-N` means N+1 bytes are committed.
    static func nextOffset(rangeHeader: String?, fallback: Int) -> Int {
        guard let rangeHeader,
            let last = rangeHeader.split(separator: "-").last,
            let lastByte = Int(last.trimmingCharacters(in: .whitespaces))
        else { return fallback }
        return lastByte + 1
    }

    private struct VideoResponse: Decodable {
        struct Status: Decodable {
            let privacyStatus: String
        }
        let id: String
        let status: Status
    }

    private static func parseResult(_ body: Data) throws -> UploadResult {
        guard let video = try? JSONDecoder().decode(VideoResponse.self, from: body) else {
            throw UploadError.badResponse(200)
        }
        return UploadResult(videoID: video.id, privacyStatus: video.status.privacyStatus)
    }

    private static func error(status: Int, body: Data) -> UploadError {
        if status == 403, String(decoding: body, as: UTF8.self).contains("quotaExceeded") {
            return .quotaExceeded
        }
        return .badResponse(status)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter YouTubeUploaderTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/YouTubeUploader.swift Tests/QuickTubeCoreTests/YouTubeUploaderTests.swift
git commit -m "Add resumable YouTube uploader"
```

---

### Task 8: AppState

**Files:**
- Create: `Sources/QuickTubeCore/AppState.swift`
- Test: `Tests/QuickTubeCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `VideoUploader`, `UploadResult`, `ShareLink`, `RecordingNaming`, `AuthError`, `UploadError`.
- Produces: `protocol ScreenRecorder: Sendable { func start() async throws; func stop() async throws -> URL }`, `enum RecorderError: Error, Equatable { screenPermissionDenied, microphonePermissionDenied, noDisplay, alreadyRecording, notRecording }`, `@MainActor protocol Notifier: AnyObject { linkReady(_:isUnlisted:); failed(_:) }`, `enum Phase: Equatable, Sendable { idle, recording, uploading(progress: Double), done(link: URL), failed(message: String, file: URL?) }`, `@MainActor @Observable final class AppState` with `init(recorder:uploader:notifier:now:)`, `phase`, `lastLink`, `toggle() async`, `retry() async`, `static func message(for: Error) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import QuickTubeCore
import Testing

final class FakeRecorder: ScreenRecorder, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    var file = URL(fileURLWithPath: "/tmp/rec.mp4")
    var starts = 0
    var stops = 0

    func start() async throws {
        starts += 1
        if let startError { throw startError }
    }

    func stop() async throws -> URL {
        stops += 1
        if let stopError { throw stopError }
        return file
    }
}

final class FakeUploader: VideoUploader, @unchecked Sendable {
    var result = UploadResult(videoID: "abc123", privacyStatus: "unlisted")
    var error: Error?
    var progressValues: [Double] = []
    var uploads: [(URL, String)] = []

    func upload(file: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult {
        uploads.append((file, title))
        for value in progressValues {
            progress(value)
            for _ in 0..<5 { await Task.yield() }
        }
        if let error { throw error }
        return result
    }
}

@MainActor final class FakeNotifier: Notifier {
    var links: [(URL, Bool)] = []
    var failures: [String] = []

    func linkReady(_ url: URL, isUnlisted: Bool) { links.append((url, isUnlisted)) }
    func failed(_ message: String) { failures.append(message) }
}

@MainActor
@Suite struct AppStateTests {
    let recorder = FakeRecorder()
    let uploader = FakeUploader()
    let notifier = FakeNotifier()
    let now = Date(timeIntervalSince1970: 1_791_624_600)

    func makeState() -> AppState {
        AppState(recorder: recorder, uploader: uploader, notifier: notifier, now: { now })
    }

    @Test func toggleStartsRecording() async {
        let state = makeState()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 1)
    }

    @Test func secondToggleStopsUploadsAndPublishesLink() async {
        let state = makeState()
        await state.toggle()
        await state.toggle()
        let link = URL(string: "https://youtu.be/abc123")!
        #expect(state.phase == .done(link: link))
        #expect(state.lastLink == link)
        #expect(uploader.uploads.count == 1)
        #expect(uploader.uploads[0].0 == recorder.file)
        #expect(uploader.uploads[0].1 == RecordingNaming.title(for: now))
        #expect(notifier.links.count == 1)
        #expect(notifier.links[0].1 == true)
    }

    @Test func progressUpdatesPhaseWhileUploading() async {
        uploader.progressValues = [0.25, 0.75]
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
    }

    @Test func privateUploadStillPublishesLinkWithWarning() async {
        uploader.result = UploadResult(videoID: "p1", privacyStatus: "private")
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(notifier.links[0].1 == false)
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/p1")!))
    }

    @Test func recorderStartFailureGoesToFailedWithoutFile() async {
        recorder.startError = RecorderError.screenPermissionDenied
        let state = makeState()
        await state.toggle()
        #expect(state.phase == .failed(message: AppState.message(for: RecorderError.screenPermissionDenied), file: nil))
        #expect(notifier.failures.count == 1)
    }

    @Test func uploadFailureKeepsFileAndRetryWorks() async {
        uploader.error = UploadError.exhaustedRetries
        let state = makeState()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .failed(message: AppState.message(for: UploadError.exhaustedRetries), file: recorder.file))

        uploader.error = nil
        await state.retry()
        #expect(state.phase == .done(link: URL(string: "https://youtu.be/abc123")!))
        #expect(uploader.uploads.count == 2)
    }

    @Test func retryWithoutFileIsNoop() async {
        let state = makeState()
        await state.retry()
        #expect(state.phase == .idle)
        #expect(uploader.uploads.isEmpty)
    }

    @Test func toggleIsIgnoredWhileUploading() async {
        uploader.progressValues = [0.5]
        let state = makeState()
        await state.toggle()
        async let upload: Void = state.toggle()
        await Task.yield()
        await state.toggle()  // ignored: still uploading
        await upload
        #expect(recorder.starts == 1)
        #expect(uploader.uploads.count == 1)
    }

    @Test func toggleAfterDoneStartsAgain() async {
        let state = makeState()
        await state.toggle()
        await state.toggle()
        await state.toggle()
        #expect(state.phase == .recording)
        #expect(recorder.starts == 2)
    }

    @Test func messagesAreHumanReadable() {
        #expect(AppState.message(for: AuthError.notSignedIn) == "Sign in to Google in Settings, then retry the upload.")
        #expect(AppState.message(for: AuthError.tokenRevoked) == "Google sign-in expired. Sign in again in Settings.")
        #expect(AppState.message(for: UploadError.quotaExceeded) == "YouTube API quota exhausted for today. Retry tomorrow.")
        #expect(AppState.message(for: RecorderError.screenPermissionDenied) == "Allow Screen Recording for QuickTube in System Settings → Privacy & Security.")
        #expect(AppState.message(for: RecorderError.microphonePermissionDenied) == "Allow Microphone for QuickTube in System Settings → Privacy & Security.")
        #expect(AppState.message(for: UploadError.badResponse(500)) == "Upload failed: badResponse(500)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateTests`
Expected: compile error.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Observation

public protocol ScreenRecorder: Sendable {
    func start() async throws
    /// Returns the finished file.
    func stop() async throws -> URL
}

public enum RecorderError: Error, Equatable {
    case screenPermissionDenied
    case microphonePermissionDenied
    case noDisplay
    case alreadyRecording
    case notRecording
}

/// Side effects of a finished or failed cycle: clipboard, notification.
@MainActor
public protocol Notifier: AnyObject {
    func linkReady(_ url: URL, isUnlisted: Bool)
    func failed(_ message: String)
}

public enum Phase: Equatable, Sendable {
    case idle
    case recording
    case uploading(progress: Double)
    case done(link: URL)
    case failed(message: String, file: URL?)
}

/// idle → recording → uploading → done; failed keeps the file for a retry.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: Phase = .idle
    public private(set) var lastLink: URL?

    private let recorder: ScreenRecorder
    private let uploader: VideoUploader
    private let notifier: Notifier
    private let now: @Sendable () -> Date

    public init(
        recorder: ScreenRecorder,
        uploader: VideoUploader,
        notifier: Notifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.uploader = uploader
        self.notifier = notifier
        self.now = now
    }

    /// The hotkey action.
    public func toggle() async {
        switch phase {
        case .idle, .done, .failed:
            await startRecording()
        case .recording:
            await stopAndUpload()
        case .uploading:
            break
        }
    }

    public func retry() async {
        guard case .failed(_, let file?) = phase else { return }
        await upload(file)
    }

    private func startRecording() async {
        do {
            try await recorder.start()
            phase = .recording
        } catch {
            fail(error, file: nil)
        }
    }

    private func stopAndUpload() async {
        let file: URL
        do {
            file = try await recorder.stop()
        } catch {
            fail(error, file: nil)
            return
        }
        await upload(file)
    }

    private func upload(_ file: URL) async {
        phase = .uploading(progress: 0)
        do {
            let result = try await uploader.upload(file: file, title: RecordingNaming.title(for: now())) { value in
                Task { @MainActor in self.setProgress(value) }
            }
            let link = ShareLink.url(forVideoID: result.videoID)
            lastLink = link
            phase = .done(link: link)
            notifier.linkReady(link, isUnlisted: result.isUnlisted)
        } catch {
            fail(error, file: file)
        }
    }

    private func setProgress(_ value: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: value)
    }

    private func fail(_ error: Error, file: URL?) {
        let message = Self.message(for: error)
        phase = .failed(message: message, file: file)
        notifier.failed(message)
    }

    public static func message(for error: Error) -> String {
        switch error {
        case AuthError.notSignedIn, AuthError.missingClient:
            return "Sign in to Google in Settings, then retry the upload."
        case AuthError.tokenRevoked:
            return "Google sign-in expired. Sign in again in Settings."
        case UploadError.quotaExceeded:
            return "YouTube API quota exhausted for today. Retry tomorrow."
        case RecorderError.screenPermissionDenied:
            return "Allow Screen Recording for QuickTube in System Settings → Privacy & Security."
        case RecorderError.microphonePermissionDenied:
            return "Allow Microphone for QuickTube in System Settings → Privacy & Security."
        default:
            return "Upload failed: \(error)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppStateTests`
Expected: 10 tests pass. If `toggleIsIgnoredWhileUploading` is flaky, replace the `Task.yield()` with a loop of five yields.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTubeCore/AppState.swift Tests/QuickTubeCoreTests/AppStateTests.swift
git commit -m "Add AppState state machine"
```

---

### Task 9: Recorder (ScreenCaptureKit)

**Files:**
- Create: `Sources/QuickTubeCore/Recorder.swift`

**Interfaces:**
- Consumes: `ScreenRecorder`, `RecorderError`, `RecordingNaming`.
- Produces: `actor Recorder: ScreenRecorder { static let defaultDirectory: URL; init(directory: URL = defaultDirectory) }`.

No unit test: ScreenCaptureKit needs a TCC grant and a display. It compiles here and is verified end-to-end in Task 11.

- [ ] **Step 1: Write the recorder**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records the display under the cursor with microphone audio to an HEVC .mp4.
public actor Recorder: ScreenRecorder {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Movies/QuickTube")

    private let directory: URL
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var fileURL: URL?
    private let delegate = RecorderDelegate()

    public init(directory: URL = Recorder.defaultDirectory) {
        self.directory = directory
    }

    public func start() async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphonePermissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenPermissionDenied
        }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard
            let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(cursor) })
                ?? content.displays.first
        else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * filter.pointPixelScale)
        configuration.height = Int(filter.contentRect.height * filter.pointPixelScale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = true

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: RecordingNaming.fileName(for: Date()))
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .hevc

        delegate.reset()
        let output = SCRecordingOutput(configuration: recording, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.fileURL = url
    }

    public func stop() async throws -> URL {
        guard let stream, let output, let fileURL else { throw RecorderError.notRecording }
        self.stream = nil
        self.output = nil
        self.fileURL = nil
        try await stream.stopCapture()
        try await delegate.waitUntilFinished()
        try? stream.removeRecordingOutput(output)
        return fileURL
    }
}

/// Bridges the delegate callbacks to one awaitable "file is closed" signal.
private final class RecorderDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Error>?

    func reset() {
        lock.withLock {
            finished = false
            failure = nil
            waiter = nil
        }
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                if finished {
                    if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
                } else {
                    waiter = continuation
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            failure = error
            if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
            waiter = nil
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish(nil) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { finish(error) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(error) }
}
```

- [ ] **Step 2: Build**

Run: `swift build && swift test`
Expected: builds clean under Swift 6; all tests still pass. If the compiler rejects `SCRecordingOutput(configuration:delegate:)` the SDK is older than macOS 15: run `sudo xcode-select -s /Applications/Xcode.app` and check `xcrun --show-sdk-version` ≥ 15.

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickTubeCore/Recorder.swift
git commit -m "Add ScreenCaptureKit recorder"
```

---

### Task 10: App target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/QuickTube/Info.plist`, `Sources/QuickTube/QuickTubeApp.swift`, `Sources/QuickTube/AppModel.swift`, `Sources/QuickTube/HotkeyManager.swift`, `Sources/QuickTube/AppNotifier.swift`, `Sources/QuickTube/MenuContent.swift`, `Sources/QuickTube/SettingsView.swift`, `Makefile`

**Interfaces:**
- Consumes: everything from `QuickTubeCore`.
- Produces: `QuickTube.app` via `make app`; `make install` copies it to `/Applications`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickTube",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuickTubeCore", targets: ["QuickTubeCore"]),
        .executable(name: "QuickTube", targets: ["QuickTube"]),
    ],
    targets: [
        .target(name: "QuickTubeCore"),
        .executableTarget(
            name: "QuickTube",
            dependencies: ["QuickTubeCore"],
            exclude: ["Info.plist"]),
        .testTarget(name: "QuickTubeCoreTests", dependencies: ["QuickTubeCore"]),
    ]
)
```

- [ ] **Step 2: Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>QuickTube</string>
    <key>CFBundleIdentifier</key>
    <string>com.wansiedler.quicktube</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>QuickTube</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>QuickTube records your voice with the screen.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>QuickTube records the screen to upload it to YouTube.</string>
</dict>
</plist>
```

- [ ] **Step 3: HotkeyManager.swift**

```swift
import AppKit
import Carbon

/// One global hotkey through Carbon; no Accessibility permission needed.
@MainActor
final class HotkeyManager {
    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32  // Carbon mask: cmdKey | optionKey | controlKey | shiftKey
        var label: String

        static let `default` = Combo(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘R")

        init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        /// nil when the event has no modifier; a bare key must not become a global hotkey.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
                return nil
            }
            var mask: UInt32 = 0
            var label = ""
            if flags.contains(.control) {
                mask |= UInt32(controlKey)
                label += "⌃"
            }
            if flags.contains(.option) {
                mask |= UInt32(optionKey)
                label += "⌥"
            }
            if flags.contains(.shift) {
                mask |= UInt32(shiftKey)
                label += "⇧"
            }
            if flags.contains(.command) {
                mask |= UInt32(cmdKey)
                label += "⌘"
            }
            self.init(keyCode: UInt32(event.keyCode), modifiers: mask, label: label + characters.uppercased())
        }
    }

    var onPress: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.onPress() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ combo: Combo) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: 0x5154_5542, id: 1)  // "QTUB"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
```

- [ ] **Step 4: AppNotifier.swift**

```swift
import AppKit
import QuickTubeCore
import UserNotifications

/// Clipboard plus a user notification. Without a bundle (swift run) it logs instead.
@MainActor
final class AppNotifier: Notifier {
    func linkReady(_ url: URL, isUnlisted: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        if isUnlisted {
            post(title: "Link copied", body: url.absoluteString)
        } else {
            post(
                title: "Uploaded as PRIVATE — link copied",
                body: "YouTube locked the video to private because the API project is unverified. \(url.absoluteString)")
        }
    }

    func failed(_ message: String) {
        post(title: "QuickTube", body: message)
    }

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("\(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 5: AppModel.swift**

```swift
import AppKit
import Observation
import QuickTubeCore

/// Wires Core to the UI and owns the user-facing settings.
@MainActor
@Observable
final class AppModel {
    let auth: GoogleAuth
    let state: AppState
    private let hotkey = HotkeyManager()
    private static let comboKey = "hotkey.combo"

    var combo: HotkeyManager.Combo {
        didSet {
            hotkey.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: Self.comboKey)
            }
        }
    }
    var clientID = ""
    var clientSecret = ""
    var signedIn = false
    var authMessage: String?

    init() {
        let auth = GoogleAuth(store: KeychainStore())
        self.auth = auth
        self.state = AppState(
            recorder: Recorder(),
            uploader: YouTubeUploader(tokens: auth),
            notifier: AppNotifier())
        self.combo =
            UserDefaults.standard.data(forKey: Self.comboKey)
            .flatMap { try? JSONDecoder().decode(HotkeyManager.Combo.self, from: $0) } ?? .default
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            Task { await self.state.toggle() }
        }
        hotkey.register(combo)
        AppNotifier.requestPermission()
        refreshAuth()
    }

    func refreshAuth() {
        Task {
            signedIn = (try? await auth.isSignedIn()) ?? false
            if let client = try? await auth.client() {
                clientID = client.id
                clientSecret = client.secret
            }
        }
    }

    func saveClient() {
        let client = OAuthClient(
            id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                try await auth.setClient(client)
                authMessage = "Client saved."
            } catch {
                authMessage = "Could not save to Keychain: \(error)"
            }
        }
    }

    func signIn() {
        authMessage = "Waiting for the browser…"
        Task {
            do {
                try await auth.signIn { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                signedIn = true
                authMessage = "Signed in."
            } catch {
                authMessage = AppState.message(for: error)
            }
        }
    }

    func signOut() {
        Task {
            try? await auth.signOut()
            signedIn = false
            authMessage = nil
        }
    }

    func copyLastLink() {
        guard let link = state.lastLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Recorder.defaultDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.defaultDirectory)
    }
}
```

- [ ] **Step 6: MenuContent.swift**

```swift
import QuickTubeCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(statusText)
        Divider()
        switch model.state.phase {
        case .recording:
            Button("Stop Recording and Upload") { Task { await model.state.toggle() } }
        case .uploading:
            Button("Uploading…") {}.disabled(true)
        default:
            Button("Start Recording") { Task { await model.state.toggle() } }
        }
        if case .failed(_, let file) = model.state.phase, file != nil {
            Button("Retry Upload") { Task { await model.state.retry() } }
        }
        if model.state.lastLink != nil {
            Button("Copy Last Link") { model.copyLastLink() }
        }
        Button("Open Recordings Folder") { model.openRecordingsFolder() }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit QuickTube") { NSApplication.shared.terminate(nil) }
    }

    private var statusText: String {
        switch model.state.phase {
        case .idle: "Ready — \(model.combo.label)"
        case .recording: "Recording… press \(model.combo.label) to stop"
        case .uploading(let progress): "Uploading \(Int(progress * 100))%"
        case .done(let link): "Uploaded: \(link.absoluteString)"
        case .failed(let message, _): "Failed: \(message)"
        }
    }
}

extension Phase {
    var symbolName: String {
        switch self {
        case .idle, .done: "record.circle"
        case .recording: "stop.circle.fill"
        case .uploading: "arrow.up.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}
```

- [ ] **Step 7: SettingsView.swift**

```swift
import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("Google") {
                TextField("OAuth client ID", text: $model.clientID)
                SecureField("OAuth client secret", text: $model.clientSecret)
                HStack {
                    Button("Save client") { model.saveClient() }
                    Spacer()
                    if model.signedIn {
                        Text("Signed in").foregroundStyle(.secondary)
                        Button("Sign out") { model.signOut() }
                    } else {
                        Button("Sign in with Google") { model.signIn() }
                    }
                }
                if let message = model.authMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Shortcut") {
                HStack {
                    Text(model.combo.label).font(.title3.monospaced())
                    Spacer()
                    Button(listening ? "Press keys…" : "Change") { startListening() }
                        .disabled(listening)
                }
                Text("Hold at least one modifier.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onDisappear { stopListening() }
    }

    private func startListening() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let combo = HotkeyManager.Combo(event: event) {
                model.combo = combo
            }
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        listening = false
    }
}
```

- [ ] **Step 8: QuickTubeApp.swift**

```swift
import QuickTubeCore
import SwiftUI

@main
struct QuickTubeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            if case .uploading(let progress) = model.state.phase {
                Label("\(Int(progress * 100))%", systemImage: model.state.phase.symbolName)
            } else {
                Image(systemName: model.state.phase.symbolName)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
```

- [ ] **Step 9: Makefile** (recipe lines start with a TAB)

```make
APP      := QuickTube.app
BIN      := .build/release/QuickTube
PLIST    := Sources/QuickTube/Info.plist
# First "Apple Development" identity in the login keychain; ad-hoc ("-") otherwise.
# A stable identity keeps the Screen Recording grant across rebuilds.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ifeq ($(IDENTITY),)
IDENTITY := -
endif

.PHONY: build app install test lint clean

build:
	swift build -c release --product QuickTube

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/QuickTube
	cp $(PLIST) $(APP)/Contents/Info.plist
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp=none $(APP)
	@echo "Signed with: $(IDENTITY)"

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed /Applications/$(APP)"

test:
	swift test --enable-code-coverage

lint:
	xcrun swift-format lint --strict --recursive Package.swift Sources Tests

clean:
	rm -rf .build $(APP)
```

- [ ] **Step 10: Build and fix Swift 6 diagnostics**

Run: `swift build -c release --product QuickTube 2>&1 | tail -30`
Expected: clean build. Likely diagnostics and their fixes:
- "capture of non-sendable" on the `NSEvent` monitor closure → annotate `{ @MainActor event in … }`.
- `@Bindable` requires `AppModel` to be `@Observable` — it is; keep `import Observation`.
- `--options runtime` with an ad-hoc identity fails → drop `--options runtime` when `IDENTITY` is `-` (`codesign --force --sign - $(APP)`).

- [ ] **Step 11: Run the test suite and lint**

Run: `swift test && make lint`
Expected: all green.

- [ ] **Step 12: Commit**

```bash
git add Package.swift Makefile Sources/QuickTube
git commit -m "Add menu bar app, hotkey, settings and bundle Makefile"
```

---

### Task 11: End-to-end manual check

**Files:** none.

- [ ] **Step 1: Build and install**

```bash
make install && open /Applications/QuickTube.app
```

- [ ] **Step 2: Google Cloud**

In the Google Cloud console: enable "YouTube Data API v3"; OAuth consent screen → External → publish to "In production" (otherwise refresh tokens die after 7 days); Credentials → Create OAuth client ID → type "Desktop app". Copy ID and secret into QuickTube → Settings, "Save client", "Sign in with Google". The browser must land on a page saying "You can close this window".

- [ ] **Step 3: Record**

Press `⌃⌥⌘R`. macOS asks for Screen Recording and Microphone the first time; grant both and press again. Talk for ten seconds, press `⌃⌥⌘R`. The icon shows an upload percentage, then a notification "Link copied". Paste in a browser: the video plays, visibility is unlisted, audio is there.

- [ ] **Step 4: Record what you saw**

If the notification says "Uploaded as PRIVATE": the API project is post-2020 and unverified. That is the known external constraint, not a bug; note it in the PR.

Check `~/Movies/QuickTube/` holds the file.

---

### Task 12: CI floors, README, PR

**Files:**
- Modify: `.github/workflows/ci.yml` (coverage floors dict)
- Create: `README.md`

- [ ] **Step 1: Coverage floors**

In `.github/workflows/ci.yml`, replace

```python
          floors = {"ShareLink.swift": 100.0}
```

with

```python
          floors = {
              "ShareLink.swift": 100.0,
              "PKCE.swift": 100.0,
              "RecordingNaming.swift": 100.0,
              "AppState.swift": 95.0,
              "YouTubeUploader.swift": 90.0,
              "GoogleAuth.swift": 85.0,
          }
```

Then verify the numbers locally before pushing:

```bash
swift test --enable-code-coverage >/dev/null && python3 - "$(swift test --show-codecov-path)" <<'EOF'
import json, os, sys
e = json.load(open(sys.argv[1]))
for d in e["data"]:
    for f in d["files"]:
        if "/Sources/" in f["filename"]:
            print(f"{os.path.basename(f['filename'])}: {f['summary']['lines']['percent']:.1f}%")
EOF
```

Lower a floor only to the measured value minus nothing: a floor documents what the tests actually cover.

- [ ] **Step 2: README.md**

```markdown
# QuickTube

Menu bar app for macOS 15+: press a hotkey, record the screen with your
voice, press it again, and the YouTube link lands on your clipboard.

## Install

```bash
make install
open /Applications/QuickTube.app
```

`make app` builds `QuickTube.app` in the repo; `make install` copies it to
`/Applications`. The bundle is signed with the first "Apple Development"
identity in your keychain, or ad-hoc if there is none (then macOS re-asks
for Screen Recording after each rebuild).

## Google setup (once)

1. Google Cloud console → enable **YouTube Data API v3**.
2. **OAuth consent screen** → External → publish to **In production**.
   In "Testing" the refresh token expires after 7 days.
3. **Credentials** → Create OAuth client ID → **Desktop app**.
4. QuickTube menu → Settings → paste client ID and secret → Save client →
   Sign in with Google.

Known limit: an API project created after 2020-07-28 that has not passed
Google's compliance audit uploads as **private** no matter what. QuickTube
tells you in the notification; the link is still copied.

Quota: each upload costs 1600 of the default 10000 daily units, about six
recordings a day.

## Use

| Action | How |
|---|---|
| Start recording | `⌃⌥⌘R` (change in Settings) |
| Stop and upload | `⌃⌥⌘R` again |
| Retry a failed upload | menu → Retry Upload |
| Find the files | menu → Open Recordings Folder (`~/Movies/QuickTube`) |

Files are never deleted automatically.

## Develop

```bash
swift test
make lint
```
```

- [ ] **Step 3: Commit, push, draft PR**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "Add README and raise coverage floors"
git -c credential.helper='!gh auth git-credential' push -u origin feature/v1
gh pr create --draft --base main --head feature/v1 --title "QuickTube v1: record, upload, copy link" --body "Implements docs/superpowers/specs/2026-10-03-quicktube-design.md. Manual end-to-end check: <fill in what Task 11 showed>."
```

Expected: CI green on the PR.
