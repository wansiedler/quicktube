import CoreMedia
import Foundation

public enum TelegramError: Error, Equatable {
    case notConfigured
    case fileTooLarge(limit: Int, actual: Int)
    case apiError(String)
    case badResponse(Int)
    /// A transport failure (offline, DNS, TLS, timeout); the text is token-free.
    case network(String)
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
    private let mobileFriendly: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let videoInfo: @Sendable (URL) async throws -> VideoInfo
    private let transcode: Transcode

    /// `VideoTranscoder.transcode`'s shape: input, plan, output, progress → written file.
    public typealias Transcode =
        @Sendable (
            URL, TranscodePlan, URL, @escaping @Sendable (Double) -> Void
        ) async throws -> URL

    /// `limitBytes`, `compressToFit`, `allowDownscale` and `mobileFriendly` are read at each upload, so Settings
    /// changes apply immediately. `mobileFriendly` sends H.264 at most 1080p (see `shouldTranscode`).
    /// `transcode` defaults to `VideoTranscoder.transcode`, logging through `log`.
    public init(
        store: SecretStore,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.telegram.org")!,
        limitBytes: @escaping @Sendable () -> Int = { TelegramUploader.botAPILimit },
        compressToFit: @escaping @Sendable () -> Bool = { true },
        allowDownscale: @escaping @Sendable () -> Bool = { false },
        mobileFriendly: @escaping @Sendable () -> Bool = { true },
        log: @escaping @Sendable (String) -> Void = { _ in },
        videoInfo: @escaping @Sendable (URL) async throws -> VideoInfo = { try await VideoInfo.read($0) },
        transcode: Transcode? = nil
    ) {
        self.store = store
        self.session = session
        self.baseURL = baseURL
        self.limitBytes = limitBytes
        self.compressToFit = compressToFit
        self.allowDownscale = allowDownscale
        self.mobileFriendly = mobileFriendly
        self.log = log
        self.videoInfo = videoInfo
        self.transcode =
            transcode ?? { input, plan, output, progress in
                try await VideoTranscoder.transcode(
                    input, plan: plan, output: output, log: { log("Telegram: \($0)") }, progress: progress)
            }
    }

    /// The plan for a second attempt after the first came out at `actualBytes`: the video bitrate scaled by
    /// `limit / actual × 0.9`, never below `VideoTranscoder.minimumVideoBitrate`; size, audio and codec unchanged.
    public static func retryPlan(after plan: TranscodePlan, actualBytes: Int, limitBytes: Int)
        -> TranscodePlan
    {
        let scale = Double(limitBytes) / Double(max(1, actualBytes)) * 0.9
        let video = max(VideoTranscoder.minimumVideoBitrate, Int(Double(plan.videoBitrate) * scale))
        return TranscodePlan(
            width: plan.width, height: plan.height, videoBitrate: video, audioBitrate: plan.audioBitrate,
            codec: plan.codec)
    }

    /// Pure: true when phones can play `info` as is: H.264 with the long side at most 1920 (1080p).
    public static func isMobileReady(_ info: VideoInfo) -> Bool {
        info.codec == kCMVideoCodecType_H264
            && max(info.width, info.height) <= VideoTranscoder.mobileMaxLongSide
    }

    /// Pure: a file over `limit` is always transcoded; with `mobileFriendly` so is one that is not already
    /// `isMobileReady` (an unknown codec counts as not ready). Without `info` only the size decides.
    public static func shouldTranscode(info: VideoInfo?, size: Int, limit: Int, mobileFriendly: Bool) -> Bool
    {
        if size > limit { return true }
        guard mobileFriendly, let info else { return false }
        return !isMobileReady(info)
    }

    /// Replaces every `bot<id>:<secret>` in `text` with `bot<redacted>`. The bot token is part of the request
    /// path, so URL-carrying errors and logs must pass through this before they become visible text.
    public static func redact(_ text: String) -> String {
        text.replacing(/bot\d+:[A-Za-z0-9_\-]+/, with: "bot<redacted>")
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
        let mobile = mobileFriendly()
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
            log("Telegram: could not read video info: \(Self.redact("\(error)"))")
        }
        var sending = file
        var sendingInfo = info
        var transcoded: URL?
        defer { if let transcoded { try? FileManager.default.removeItem(at: transcoded) } }
        if Self.shouldTranscode(info: info, size: size, limit: limit, mobileFriendly: mobile) {
            guard let info else { throw TranscodeError.cannotRead }
            // Mobile-friendly: H.264 capped at 1080p, the whole size budget spent on that.
            var plan = VideoTranscoder.plan(
                info: info, limitBytes: limit, allowDownscale: allowDownscale(),
                maxLongSide: mobile ? VideoTranscoder.mobileMaxLongSide : nil, codec: mobile ? .h264 : .hevc)
            let output = Self.transcodeURL(for: file)
            transcoded = output
            context.onStatus(
                RecordingNaming.compressionLine(from: info, sizeBytes: size, to: plan, targetBytes: limit))
            let reason =
                oversized
                ? "\(size) bytes over the \(limit)-byte limit"
                : "\(size) bytes, not mobile-friendly as recorded"
            log("Telegram: \(reason), transcoding with \(plan)")
            progress(0)
            sending = try await transcode(file, plan, output) { progress($0) }
            transcoded = sending
            var newSize = Self.fileSize(sending)
            guard newSize > 0 else { throw UploadError.fileUnreadable }
            log("Telegram: attempt 1 wrote \(newSize) bytes (limit \(limit))")
            // The encoder can miss the target at very high resolutions; one retry at a proportionally lower rate.
            if newSize > limit {
                plan = Self.retryPlan(after: plan, actualBytes: newSize, limitBytes: limit)
                let line = RecordingNaming.compressionLine(
                    from: info, sizeBytes: size, to: plan, targetBytes: limit)
                context.onStatus(line.replacingOccurrences(of: "Compressing", with: "Compressing again"))
                log(
                    "Telegram: \(newSize) bytes still over the \(limit)-byte limit, transcoding again with \(plan)"
                )
                progress(0)
                sending = try await transcode(file, plan, output) { progress($0) }
                transcoded = sending
                newSize = Self.fileSize(sending)
                guard newSize > 0 else { throw UploadError.fileUnreadable }
                log("Telegram: attempt 2 wrote \(newSize) bytes (limit \(limit))")
            }
            guard newSize <= limit else { throw TelegramError.fileTooLarge(limit: limit, actual: newSize) }

            // The player proportions must match the file that is sent, not the recording.
            do {
                sendingInfo = try await videoInfo(sending)
            } catch {
                log("Telegram: could not read transcoded video info: \(Self.redact("\(error)"))")
                sendingInfo = VideoInfo(
                    width: plan.width, height: plan.height, fps: info.fps, duration: info.duration)
            }
        }

        // The caption names the file as captured and, after a transcode, the size that was sent.
        var caption = title
        if let info {
            let sent = sending == file ? nil : Self.fileSize(sending)
            caption +=
                "\n"
                + RecordingNaming.metadataLine(
                    display: context.display, info: info, sizeBytes: size, sentBytes: sent)
        }

        // Each stage reports 0 → 1 on its own; the status switch tells the UI which one is running.
        context.onStatus("Uploading")
        if transcoded != nil { progress(0) }
        let boundary = "QuickTube-\(UUID().uuidString)"
        let body = try Self.multipartBody(
            boundary: boundary, chat: configuration.chat, caption: caption, file: sending,
            dimensions: sendingInfo)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: baseURL.appending(path: "bot\(configuration.botToken)/sendVideo"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: request, fromFile: body, delegate: ProgressDelegate(progress))
        } catch let error as URLError {
            // URLError's description carries the failing URL, and with it the token.
            let text = Self.redact(error.localizedDescription)
            log("Telegram: network error \(error.code.rawValue): \(text)")
            throw TelegramError.network(text)
        }
        guard let http = response as? HTTPURLResponse else { throw TelegramError.badResponse(0) }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard http.statusCode == 200, let result = reply?.result, reply?.ok == true else {
            let text = String(decoding: data.prefix(2000), as: UTF8.self)
            log("Telegram HTTP \(http.statusCode) \(Self.redact(text))")
            if let description = reply?.description { throw TelegramError.apiError(Self.redact(description)) }
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
