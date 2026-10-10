import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct TelegramUploaderTests {
        let store = InMemorySecretStore()

        func makeUploader(maxBytes: Int = TelegramUploader.botAPILimit) -> TelegramUploader {
            StubURLProtocol.reset()
            return TelegramUploader(
                store: store, session: StubURLProtocol.makeSession(),
                baseURL: URL(string: "https://tg.example")!, maxBytes: maxBytes)
        }

        func makeFile(bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "tg-\(UUID().uuidString).mp4")
            try Data(repeating: 0xCD, count: bytes).write(to: url)
            return url
        }

        func reply(username: String?, id: Int64, messageID: Int) -> Data {
            let user = username.map { "\"username\":\"\($0)\"," } ?? ""
            return Data(
                "{\"ok\":true,\"result\":{\"message_id\":\(messageID),\"chat\":{\(user)\"id\":\(id)}}}".utf8)
        }

        @Test func sendsMultipartVideoAndLinksPublicChannel() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "123:abc", chat: "@mychan"))
            let file = try makeFile(bytes: 16)
            StubURLProtocol.enqueue(
                .init(status: 200, body: reply(username: "mychan", id: -1001, messageID: 42)))

            let result = try await uploader.upload(file: file, title: "2026-10-10 16.00.00") { _ in }

            #expect(result.link == URL(string: "https://t.me/mychan/42"))
            #expect(result.isUnlisted)
            let request = StubURLProtocol.requests[0]
            #expect(request.url?.path == "/bot123:abc/sendVideo")
            #expect(
                request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=")
                    == true)
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("name=\"chat_id\"\r\n\r\n@mychan"))
            #expect(body.contains("name=\"caption\"\r\n\r\n2026-10-10 16.00.00"))
            #expect(body.contains("name=\"video\"; filename=\"\(file.lastPathComponent)\""))
            #expect(body.contains("Content-Type: video/mp4"))
            #expect((request.httpBody ?? Data()).count > 16)
        }

        @Test func privateChannelLinksById() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "-1001234567890"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(
                .init(status: 200, body: reply(username: nil, id: -1_001_234_567_890, messageID: 7)))
            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.link == URL(string: "https://t.me/c/1234567890/7"))
        }

        @Test func missingConfigurationIsReported() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 4)
            await #expect(throws: TelegramError.notConfigured) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func oversizedFileIsRejectedBeforeSending() async throws {
            let uploader = makeUploader(maxBytes: 10)
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 11)
            await #expect(throws: TelegramError.fileTooLarge(limit: 10, actual: 11)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func apiDescriptionIsSurfaced() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(
                .init(
                    status: 403,
                    body: Data("{\"ok\":false,\"description\":\"Forbidden: bot is not a member\"}".utf8)))
            await #expect(throws: TelegramError.apiError("Forbidden: bot is not a member")) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func configurationRoundTrip() async throws {
            let uploader = makeUploader()
            #expect(try await uploader.configuration() == nil)
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            #expect(try await uploader.configuration() == TelegramConfiguration(botToken: "t", chat: "@c"))
            try await uploader.clearConfiguration()
            #expect(try await uploader.configuration() == nil)
        }
    }
}
