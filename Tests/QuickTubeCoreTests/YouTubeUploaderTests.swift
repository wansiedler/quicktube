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
            // Status query: 6 bytes landed.
            StubURLProtocol.enqueue(.init(status: 308, headers: ["Range": "bytes=0-5"]))
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
                _ = try await uploader.upload(file: URL(fileURLWithPath: "/nonexistent/x.mp4"), title: "T") {
                    _ in
                }
            }
        }

        @Test func privateStatusIsSurfaced() async throws {
            let uploader = makeUploader(chunkSize: 8)
            let file = try makeFile(bytes: 2)
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Location": sessionURL]))
            StubURLProtocol.enqueue(
                .init(
                    status: 200, body: Data("{\"id\":\"v\",\"status\":{\"privacyStatus\":\"private\"}}".utf8))
            )
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
