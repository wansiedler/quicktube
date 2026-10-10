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
    private let limitBytes: @Sendable () -> Int
    private let compressToFit: @Sendable () -> Bool
    private let allowDownscale: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let videoInfo: @Sendable (URL) async throws -> VideoInfo
    private let transcode: Transcode

    /// `VideoTranscoder.transcode`'s shape: input, plan, output, progress → written file.
    public typealias Transcode =
        @Sendable (
            URL, TranscodePlan, URL, @escaping @Sendable (Double) -> Void
        ) async throws -> URL

    /// `limitBytes`, `compressToFit` and `allowDownscale` are read at each upload, so Settings changes apply immediately.
    public init(
        store: SecretStore,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.telegram.org")!,
        limitBytes: @escaping @Sendable () -> Int = { TelegramUploader.botAPILimit },
        compressToFit: @escaping @Sendable () -> Bool = { true },
        allowDownscale: @escaping @Sendable () -> Bool = { false },
        log: @escaping @Sendable (String) -> Void = { _ in },
        videoInfo: @escaping @Sendable (URL) async throws -> VideoInfo = { try await VideoInfo.read($0) },
        transcode: @escaping Transcode = {
            try await VideoTranscoder.transcode($0, plan: $1, output: $2, progress: $3)
        }
    ) {
        self.store = store
        self.session = session
        self.baseURL = baseURL
        self.limitBytes = limitBytes
        self.compressToFit = compressToFit
        self.allowDownscale = allowDownscale
        self.log = log
        self.videoInfo = videoInfo
        self.transcode = transcode
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
        file: URL, title: String, context: UploadContext = UploadContext(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        guard let configuration = try configuration() else { throw TelegramError.notConfigured }
        let size = Self.fileSize(file)
        guard size > 0 else { throw UploadError.fileUnreadable }
        let limit = limitBytes()
        let oversized = size > limit
        guard !oversized || compressToFit() else {
            throw TelegramError.fileTooLarge(limit: limit, actual: size)
        }

        // The caption describes the recording as captured, even when a smaller copy is sent.
        // It is a nicety; an unreadable clip must not block an upload that needs no transcode.
        var info: VideoInfo?
        do {
            info = try await videoInfo(file)
        } catch {
            log("Telegram: could not read video info: \(error)")
        }
        var caption = title
        if let info { caption += "\n" + RecordingNaming.metadataLine(display: context.display, info: info) }

        var sending = file
        var sendingInfo = info
        var transcoded: URL?
        defer { if let transcoded { try? FileManager.default.removeItem(at: transcoded) } }
        if oversized {
            guard let info else { throw TranscodeError.cannotRead }
            let plan = VideoTranscoder.plan(info: info, limitBytes: limit, allowDownscale: allowDownscale())
            let output = Self.transcodeURL(for: file)
            transcoded = output
            context.onStatus(
                RecordingNaming.compressionLine(from: info, sizeBytes: size, to: plan, targetBytes: limit))
            log("Telegram: \(size) bytes over the \(limit)-byte limit, transcoding with \(plan)")
            progress(0)
            sending = try await transcode(file, plan, output) { progress($0) }
            transcoded = sending
            let newSize = Self.fileSize(sending)
            guard newSize > 0 else { throw UploadError.fileUnreadable }
            guard newSize <= limit else { throw TelegramError.fileTooLarge(limit: limit, actual: newSize) }

            // The player proportions must match the file that is sent, not the recording.
            do {
                sendingInfo = try await videoInfo(sending)
            } catch {
                log("Telegram: could not read transcoded video info: \(error)")
                sendingInfo = VideoInfo(
                    width: plan.width, height: plan.height, fps: info.fps, duration: info.duration)
            }
        }

        // Each stage reports 0 → 1 on its own; the status switch tells the UI which one is running.
        context.onStatus("Uploading")
        if oversized { progress(0) }
        let boundary = "QuickTube-\(UUID().uuidString)"
        let body = try Self.multipartBody(
            boundary: boundary, chat: configuration.chat, caption: caption, file: sending,
            dimensions: sendingInfo)
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

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// `<stem>.telegram.mp4` next to the recording.
    static func transcodeURL(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("telegram.mp4")
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
    /// A private chat with the bot has no shareable link, so the deep link opens the message locally.
    static func messageLink(chat: Reply.Message.Chat, messageID: Int) -> URL {
        if let username = chat.username, !username.isEmpty, chat.id < 0 {
            return URL(string: "https://t.me/\(username)/\(messageID)")!
        }
        guard chat.id < 0 else {
            return URL(string: "tg://openmessage?user_id=\(chat.id)&message_id=\(messageID)")!
        }
        var id = String(chat.id)
        if id.hasPrefix("-100") { id.removeFirst(4) } else if id.hasPrefix("-") { id.removeFirst() }
        return URL(string: "https://t.me/c/\(id)/\(messageID)")!
    }

    /// Streams the video into a temporary multipart file so the request body is never held in memory.
    static func multipartBody(
        boundary: String, chat: String, caption: String, file: URL, dimensions: VideoInfo? = nil
    )
        throws -> URL
    {
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
        // Without these the Bot API guesses the player proportions and may squeeze wide videos.
        if let dimensions {
            try field("width", String(dimensions.width))
            try field("height", String(dimensions.height))
            try field("duration", String(Int(dimensions.duration.rounded())))
        }
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
