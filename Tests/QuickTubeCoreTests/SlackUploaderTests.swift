import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct SlackUploaderTests {
        let store = InMemorySecretStore()

        func makeUploader() -> SlackUploader {
            StubURLProtocol.reset()
            return SlackUploader(
                store: store, session: StubURLProtocol.makeSession(),
                apiBase: URL(string: "https://slack.example/api")!)
        }

        func makeFile(bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "sl-\(UUID().uuidString).mp4")
            try Data(repeating: 0x5A, count: bytes).write(to: url)
            return url
        }

        @Test func uploadsInThreeStepsAndReturnsPermalink() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(SlackConfiguration(token: "xoxb-1", channel: "C123"))
            let file = try makeFile(bytes: 9)
            StubURLProtocol.enqueue(
                .init(
                    status: 200,
                    body: Data(
                        "{\"ok\":true,\"upload_url\":\"https://files.slack.example/up/1\",\"file_id\":\"F1\"}"
                            .utf8)))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("OK - 9".utf8)))
            StubURLProtocol.enqueue(
                .init(
                    status: 200,
                    body: Data(
                        "{\"ok\":true,\"files\":[{\"id\":\"F1\",\"permalink\":\"https://ws.slack.com/files/U1/F1/t.mp4\"}]}"
                            .utf8)))

            let result = try await uploader.upload(file: file, title: "T") { _ in }

            #expect(result.link == URL(string: "https://ws.slack.com/files/U1/F1/t.mp4"))
            let requests = StubURLProtocol.requests
            #expect(requests.count == 3)
            #expect(requests[0].url?.path == "/api/files.getUploadURLExternal")
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-1")
            let form = String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(form.contains("filename=T.mp4"))
            #expect(form.contains("length=9"))
            #expect(requests[1].url?.absoluteString == "https://files.slack.example/up/1")
            #expect(requests[1].httpBody?.count == 9)
            #expect(requests[2].url?.path == "/api/files.completeUploadExternal")
            let json = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
            #expect(json["channel_id"] as? String == "C123")
            #expect((json["files"] as? [[String: String]])?.first?["id"] == "F1")
        }

        @Test func slackErrorCodeIsSurfaced() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(SlackConfiguration(token: "xoxb-1", channel: "C123"))
            let file = try makeFile(bytes: 2)
            StubURLProtocol.enqueue(
                .init(status: 200, body: Data("{\"ok\":false,\"error\":\"invalid_auth\"}".utf8)))
            await #expect(throws: SlackError.apiError("invalid_auth")) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func missingConfigurationIsReported() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 2)
            await #expect(throws: SlackError.notConfigured) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }
    }
}
