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
    func upload(file: URL, title: String, progress: @escaping @Sendable (Double) -> Void) async throws
        -> UploadResult
}

/// Resumable `videos.insert`: one session, fixed-size chunks, resume on failure.
public actor YouTubeUploader: VideoUploader {
    public static let endpoint = URL(
        string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status"
    )!

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
                let (body, response) = try await session.upload(
                    for: request, from: data.subdata(in: offset..<end))
                let http = try Self.http(response)
                switch http.statusCode {
                case 308:
                    offset = Self.nextOffset(
                        rangeHeader: http.value(forHTTPHeaderField: "Range"), fallback: end)
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
        guard let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location)
        else {
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
