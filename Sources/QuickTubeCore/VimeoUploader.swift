import Foundation

public enum VimeoError: Error, Equatable {
    case notConfigured
    /// A non-2xx answer; the message is Vimeo's `error` (or `developer_message`) text, else "HTTP <status>".
    case apiError(status: Int, message: String)
    /// The tus upload gave up after its retries with `offset` of `size` bytes on the server.
    case uploadIncomplete(offset: Int, size: Int)
    /// A 2xx answer without the fields QuickTube needs.
    case badResponse(Int)
}

/// Who can watch the upload; the raw value is the API's `privacy.view`.
public enum VimeoPrivacy: String, Codable, CaseIterable, Sendable {
    case unlisted
    case anybody
    case nobody

    public var label: String {
        switch self {
        case .unlisted: "Unlisted"
        case .anybody: "Public"
        case .nobody: "Only me"
        }
    }
}

public struct VimeoConfiguration: Sendable, Equatable {
    /// A personal access token with the `upload`, `private` and `edit` scopes.
    public let token: String
    public let privacy: VimeoPrivacy

    public init(token: String, privacy: VimeoPrivacy) {
        self.token = token
        self.privacy = privacy
    }
}

/// Creates the video with the tus approach, then PATCHes the file in chunks, resuming from the server's
/// `Upload-Offset` after a transient failure.
public actor VimeoUploader: VideoUploader {
    /// Keychain account of the access token.
    public static let tokenKey = "vimeo.token"
    public static let tusVersion = "1.0.0"

    private let configuration: @Sendable () throws -> VimeoConfiguration?
    private let session: URLSession
    private let apiBase: URL
    private let chunkSize: Int
    private let maxRetries: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: @Sendable (String) -> Void

    /// `configuration` is read at each upload, so Settings changes apply immediately; nil means not set up.
    public init(
        configuration: @escaping @Sendable () throws -> VimeoConfiguration?,
        session: URLSession = .shared,
        apiBase: URL = URL(string: "https://api.vimeo.com")!,
        chunkSize: Int = 32 << 20,
        maxRetries: Int = 3,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.session = session
        self.apiBase = apiBase
        self.chunkSize = max(1, chunkSize)
        self.maxRetries = maxRetries
        self.sleep = sleep
        self.log = log
    }

    /// Replaces every `bearer <token>` in `text` with `bearer <redacted>`.
    public static func redact(_ text: String) -> String {
        text.replacing(/(?i)bearer\s+[A-Za-z0-9._~+\/=\-]+/, with: "bearer <redacted>")
    }

    public func upload(
        file: URL, title: String, context: UploadContext = UploadContext(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        guard let configuration = try configuration(),
            !configuration.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw VimeoError.notConfigured }
        context.onStatus("Uploading")
        let size: Int
        let handle: FileHandle
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw UploadError.fileUnreadable }
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw UploadError.fileUnreadable
        }
        defer { try? handle.close() }

        let video = try await create(title: title, size: size, configuration: configuration)
        // The loop ends only once the server reports all bytes (PATCH or HEAD `Upload-Offset` == size).
        try await send(handle, size: size, to: video.uploadLink, progress: progress)
        return UploadResult(
            link: video.link, videoID: video.id,
            privacyStatus: video.privacy ?? configuration.privacy.rawValue)
    }

    // MARK: - Create

    private struct CreateRequest: Encodable {
        struct Upload: Encodable {
            let approach: String
            let size: Int
        }
        struct Privacy: Encodable {
            let view: String
        }
        let upload: Upload
        let name: String
        let privacy: Privacy
    }

    private struct CreateResponse: Decodable {
        struct Upload: Decodable {
            let uploadLink: URL?

            enum CodingKeys: String, CodingKey {
                case uploadLink = "upload_link"
            }
        }
        struct Privacy: Decodable {
            let view: String?
        }
        let uri: String?
        let link: URL?
        let upload: Upload?
        let privacy: Privacy?
    }

    private struct CreatedVideo {
        let id: String
        let link: URL
        let uploadLink: URL
        let privacy: String?
    }

    private func create(title: String, size: Int, configuration: VimeoConfiguration) async throws
        -> CreatedVideo
    {
        var request = URLRequest(url: apiBase.appending(path: "me/videos"))
        request.httpMethod = "POST"
        request.setValue("bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.vimeo.*+json;version=3.4", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            CreateRequest(
                upload: .init(approach: "tus", size: size), name: title,
                privacy: .init(view: configuration.privacy.rawValue)))
        let (body, response) = try await session.data(for: request)
        let http = try Self.http(response)
        guard (200..<300).contains(http.statusCode) else { throw fail(http, body: body, step: "create") }
        guard let created = try? JSONDecoder().decode(CreateResponse.self, from: body),
            let uploadLink = created.upload?.uploadLink, let link = created.link,
            let id = created.uri?.split(separator: "/").last.map(String.init)
        else {
            log("Vimeo create: HTTP \(http.statusCode) without upload_link, link or uri")
            throw VimeoError.badResponse(http.statusCode)
        }
        return CreatedVideo(id: id, link: link, uploadLink: uploadLink, privacy: created.privacy?.view)
    }

    // MARK: - tus

    /// PATCHes from the server's offset until it has all `size` bytes; up to `maxRetries` HEAD-and-resume
    /// rounds per chunk. Progress never goes back, even when HEAD reports fewer bytes than a PATCH did.
    private func send(
        _ handle: FileHandle, size: Int, to uploadLink: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var offset = 0
        var retries = 0
        var needsHead = false
        var reported = 0.0
        func report(_ offset: Int) {
            let value = Double(offset) / Double(size)
            guard value > reported else { return }
            reported = value
            progress(value)
        }
        while offset < size {
            try Task.checkCancellation()
            do {
                if needsHead {
                    try await sleep(.seconds(1 << (retries - 1)))
                    let committed = try await head(uploadLink)
                    guard committed <= size else {
                        throw VimeoError.uploadIncomplete(offset: committed, size: size)
                    }
                    if committed > offset { retries = 0 }
                    offset = committed
                    needsHead = false
                    report(offset)
                    continue
                }
                let end = min(offset + chunkSize, size)
                let chunk: Data
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    chunk = try handle.read(upToCount: end - offset) ?? Data()
                } catch {
                    throw UploadError.fileUnreadable
                }
                guard chunk.count == end - offset else { throw UploadError.fileUnreadable }
                let committed = try await patch(uploadLink, offset: offset, chunk: chunk)
                guard committed > offset, committed <= size else { throw Retry() }
                offset = committed
                retries = 0
                report(offset)
            } catch let error where Self.isRetryable(error) {
                retries += 1
                log(
                    "Vimeo upload: transient failure at \(offset) of \(size) bytes (retry \(retries)): \(error)"
                )
                guard retries <= maxRetries else {
                    throw VimeoError.uploadIncomplete(offset: offset, size: size)
                }
                needsHead = true
            }
        }
    }

    /// The new offset from the 204's `Upload-Offset`.
    private func patch(_ uploadLink: URL, offset: Int, chunk: Data) async throws -> Int {
        var request = URLRequest(url: uploadLink)
        request.httpMethod = "PATCH"
        request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: request, from: chunk)
        let http = try Self.http(response)
        switch http.statusCode {
        case 200..<300:
            guard let value = http.value(forHTTPHeaderField: "Upload-Offset"), let committed = Int(value)
            else {
                throw Retry()
            }
            return committed
        // 409: the PATCH's offset is not the server's (e.g. a replay after a lost 204); HEAD resyncs.
        case 409, 500...599:
            throw Retry()
        default:
            throw fail(http, body: body, step: "PATCH")
        }
    }

    /// How many bytes the server has.
    private func head(_ uploadLink: URL) async throws -> Int {
        var request = URLRequest(url: uploadLink)
        request.httpMethod = "HEAD"
        request.setValue(Self.tusVersion, forHTTPHeaderField: "Tus-Resumable")
        let (body, response) = try await session.data(for: request)
        let http = try Self.http(response)
        switch http.statusCode {
        case 200..<300:
            guard let value = http.value(forHTTPHeaderField: "Upload-Offset"), let committed = Int(value)
            else {
                throw Retry()
            }
            return committed
        case 500...599:
            throw Retry()
        default:
            throw fail(http, body: body, step: "HEAD")
        }
    }

    // MARK: - Helpers

    private struct Retry: Error {}

    /// Transient failures only; a cancelled request must stop the upload.
    private static func isRetryable(_ error: Error) -> Bool {
        if error is Retry { return true }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        return false
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw VimeoError.badResponse(0) }
        return http
    }

    private struct APIErrorBody: Decodable {
        let error: String?
        let developerMessage: String?

        enum CodingKeys: String, CodingKey {
            case error
            case developerMessage = "developer_message"
        }
    }

    private func fail(_ http: HTTPURLResponse, body: Data, step: String) -> VimeoError {
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        log("Vimeo \(step) HTTP \(http.statusCode) \(Self.redact(text))")
        return Self.error(status: http.statusCode, body: body)
    }

    static func error(status: Int, body: Data) -> VimeoError {
        let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: body)
        let message = [decoded?.error, decoded?.developerMessage]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return .apiError(status: status, message: redact(message ?? "HTTP \(status)"))
    }
}
