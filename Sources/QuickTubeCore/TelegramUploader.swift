import Foundation

public enum TelegramError: Error, Equatable {
    case notConfigured
    case fileTooLarge(limit: Int, actual: Int)
    case apiError(String)
    case badResponse(Int)
}

public struct TelegramConfiguration: Sendable, Equatable {
    public let botToken: String
    /// `@channel` or a numeric chat id such as `-1001234567890`.
    public let chat: String

    public init(botToken: String, chat: String) {
        self.botToken = botToken
        self.chat = chat
    }
}

/// `sendVideo` through the Bot API; the bot must be an admin of the target channel.
public actor TelegramUploader: VideoUploader {
    /// api.telegram.org refuses bigger uploads from bots.
    public static let botAPILimit = 50 << 20

    enum Key {
        static let token = "telegram.bot_token"
        static let chat = "telegram.chat"
    }

    private let store: SecretStore
    private let session: URLSession
    private let baseURL: URL
    private let maxBytes: Int
    private let log: @Sendable (String) -> Void

    public init(
        store: SecretStore,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.telegram.org")!,
        maxBytes: Int = TelegramUploader.botAPILimit,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.session = session
        self.baseURL = baseURL
        self.maxBytes = maxBytes
        self.log = log
    }

    public func configuration() throws -> TelegramConfiguration? {
        guard let token = try store.get(Key.token), let chat = try store.get(Key.chat),
            !token.isEmpty, !chat.isEmpty
        else { return nil }
        return TelegramConfiguration(botToken: token, chat: chat)
    }

    public func setConfiguration(_ configuration: TelegramConfiguration) throws {
        try store.set(configuration.botToken, for: Key.token)
        try store.set(configuration.chat, for: Key.chat)
    }

    public func clearConfiguration() throws {
        try store.delete(Key.token)
        try store.delete(Key.chat)
    }

    public func upload(
        file: URL, title: String, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        guard let configuration = try configuration() else { throw TelegramError.notConfigured }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw UploadError.fileUnreadable }
        guard size <= maxBytes else { throw TelegramError.fileTooLarge(limit: maxBytes, actual: size) }

        let boundary = "QuickTube-\(UUID().uuidString)"
        let body = try Self.multipartBody(
            boundary: boundary, chat: configuration.chat, caption: title, file: file)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: baseURL.appending(path: "bot\(configuration.botToken)/sendVideo"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(
            for: request, fromFile: body, delegate: ProgressDelegate(progress))
        guard let http = response as? HTTPURLResponse else { throw TelegramError.badResponse(0) }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard http.statusCode == 200, let result = reply?.result, reply?.ok == true else {
            let text = String(decoding: data.prefix(2000), as: UTF8.self)
            log("Telegram HTTP \(http.statusCode) \(text)")
            if let description = reply?.description { throw TelegramError.apiError(description) }
            throw TelegramError.badResponse(http.statusCode)
        }
        progress(1)
        return UploadResult(link: Self.messageLink(chat: result.chat, messageID: result.messageID))
    }

    // MARK: - Wire format

    struct Reply: Decodable {
        struct Message: Decodable {
            struct Chat: Decodable {
                let id: Int64
                let username: String?
            }
            let messageID: Int
            let chat: Chat

            enum CodingKeys: String, CodingKey {
                case messageID = "message_id"
                case chat
            }
        }
        let ok: Bool
        let result: Message?
        let description: String?
    }

    /// Public channels link by username; private channels and groups by their id without the `-100`.
    static func messageLink(chat: Reply.Message.Chat, messageID: Int) -> URL {
        if let username = chat.username, !username.isEmpty {
            return URL(string: "https://t.me/\(username)/\(messageID)")!
        }
        var id = String(chat.id)
        if id.hasPrefix("-100") { id.removeFirst(4) } else if id.hasPrefix("-") { id.removeFirst() }
        return URL(string: "https://t.me/c/\(id)/\(messageID)")!
    }

    /// Streams the video into a temporary multipart file so the request body is never held in memory.
    static func multipartBody(boundary: String, chat: String, caption: String, file: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(
            path: "quicktube-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        func field(_ name: String, _ value: String) throws {
            try writer.write(
                contentsOf: Data(
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                        .utf8))
        }
        try field("chat_id", chat)
        try field("caption", caption)
        try field("supports_streaming", "true")
        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        try writer.write(
            contentsOf: Data(
                ("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\n"
                    + "Content-Type: video/mp4\r\n\r\n").utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}

/// Forwards URLSession's byte counts to the upload progress callback.
final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progress: @Sendable (Double) -> Void

    init(_ progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
