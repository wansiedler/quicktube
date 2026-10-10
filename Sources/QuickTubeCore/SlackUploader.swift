import Foundation

public enum SlackError: Error, Equatable {
    case notConfigured
    /// Slack's `error` field, e.g. `not_in_channel` or `invalid_auth`.
    case apiError(String)
    case badResponse(Int)
}

public struct SlackConfiguration: Sendable, Equatable {
    /// A bot token (`xoxb-…`) from an app with the `files:write` scope.
    public let token: String
    /// Channel ID such as `C0123456789`; the bot must be a member.
    public let channel: String

    public init(token: String, channel: String) {
        self.token = token
        self.channel = channel
    }
}

/// Three-step external upload: get an upload URL, PUT the bytes, complete into a channel.
public actor SlackUploader: VideoUploader {
    enum Key {
        static let token = "slack.token"
        static let channel = "slack.channel"
    }

    private let store: SecretStore
    private let session: URLSession
    private let apiBase: URL
    private let log: @Sendable (String) -> Void

    public init(
        store: SecretStore,
        session: URLSession = .shared,
        apiBase: URL = URL(string: "https://slack.com/api")!,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.session = session
        self.apiBase = apiBase
        self.log = log
    }

    public func configuration() throws -> SlackConfiguration? {
        guard let token = try store.get(Key.token), let channel = try store.get(Key.channel),
            !token.isEmpty, !channel.isEmpty
        else { return nil }
        return SlackConfiguration(token: token, channel: channel)
    }

    public func setConfiguration(_ configuration: SlackConfiguration) throws {
        try store.set(configuration.token, for: Key.token)
        try store.set(configuration.channel, for: Key.channel)
    }

    public func clearConfiguration() throws {
        try store.delete(Key.token)
        try store.delete(Key.channel)
    }

    public func upload(
        file: URL, title: String, context: UploadContext = UploadContext(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        guard let configuration = try configuration() else { throw SlackError.notConfigured }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw UploadError.fileUnreadable }

        let ticket: UploadTicket = try await call(
            "files.getUploadURLExternal", token: configuration.token,
            form: ["filename": "\(title).mp4", "length": String(size)])

        var put = URLRequest(url: ticket.uploadURL)
        put.httpMethod = "POST"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (putBody, putResponse) = try await session.upload(
            for: put, fromFile: file, delegate: ProgressDelegate(progress))
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            log("Slack upload HTTP \(status) \(String(decoding: putBody.prefix(2000), as: UTF8.self))")
            throw SlackError.badResponse(status)
        }

        let completed: Completion = try await call(
            "files.completeUploadExternal", token: configuration.token,
            json: Completion.Request(
                files: [.init(id: ticket.fileID, title: title)], channelID: configuration.channel))
        guard let shared = completed.files.first, let link = shared.permalink else {
            throw SlackError.badResponse(200)
        }
        progress(1)
        return UploadResult(link: link)
    }

    // MARK: - Wire format

    private struct UploadTicket: Decodable {
        let uploadURL: URL
        let fileID: String

        enum CodingKeys: String, CodingKey {
            case uploadURL = "upload_url"
            case fileID = "file_id"
        }
    }

    private struct Completion: Decodable {
        struct Request: Encodable {
            struct File: Encodable {
                let id: String
                let title: String
            }
            let files: [File]
            let channelID: String

            enum CodingKeys: String, CodingKey {
                case files
                case channelID = "channel_id"
            }
        }
        struct File: Decodable {
            let id: String
            let permalink: URL?
        }
        let files: [File]
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let ok: Bool
        let error: String?
    }

    private func call<Payload: Decodable>(
        _ method: String, token: String, form: [String: String]? = nil, json: (some Encodable)? = nil as Int?
    ) async throws -> Payload {
        var request = URLRequest(url: apiBase.appending(path: method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formEncode(form).utf8)
        } else if let json {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SlackError.badResponse(0) }
        let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: body)
        guard http.statusCode == 200, envelope?.ok == true else {
            log(
                "Slack \(method) HTTP \(http.statusCode) \(String(decoding: body.prefix(2000), as: UTF8.self))"
            )
            if let error = envelope?.error { throw SlackError.apiError(error) }
            throw SlackError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(Payload.self, from: body)
    }
}
