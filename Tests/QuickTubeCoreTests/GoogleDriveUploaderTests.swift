import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct GoogleDriveUploaderTests {
        func makeUploader() -> GoogleDriveUploader {
            StubURLProtocol.reset()
            return GoogleDriveUploader(
                tokens: FixedTokens(), session: StubURLProtocol.makeSession(),
                apiBase: URL(string: "https://drive.example/v3")!,
                uploadBase: URL(string: "https://drive.example/upload")!)
        }

        func makeFile(bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "gd-\(UUID().uuidString).mp4")
            try Data(repeating: 0xEE, count: bytes).write(to: url)
            return url
        }

        @Test func createsFolderUploadsAndSharesByLink() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 12)
            // Folder lookup, then folder creation.
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"files\":[]}".utf8)))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"id\":\"folder1\"}".utf8)))
            StubURLProtocol.enqueue(
                .init(status: 200, headers: ["Location": "https://drive.example/session/1"]))
            StubURLProtocol.enqueue(
                .init(
                    status: 200,
                    body: Data(
                        "{\"id\":\"file9\",\"webViewLink\":\"https://drive.google.com/file/d/file9/view\"}"
                            .utf8)))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"id\":\"perm1\"}".utf8)))

            let result = try await uploader.upload(file: file, title: "2026-10-10 17.00.00") { _ in }

            #expect(result.link == URL(string: "https://drive.google.com/file/d/file9/view"))
            let requests = StubURLProtocol.requests
            #expect(requests.count == 5)
            #expect(requests[0].url?.path == "/v3/files")
            #expect(requests[0].url?.query?.contains("mimeType") == true)
            #expect(requests[1].httpMethod == "POST")
            let folderMeta =
                try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: String]
            #expect(folderMeta["name"] == "QuickTube")
            #expect(requests[2].url?.query?.contains("uploadType=resumable") == true)
            let meta = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
            #expect(meta["name"] as? String == "2026-10-10 17.00.00.mp4")
            #expect(meta["parents"] as? [String] == ["folder1"])
            #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            #expect(requests[3].httpMethod == "PUT")
            #expect(requests[3].httpBody?.count == 12)
            #expect(requests[4].url?.path == "/v3/files/file9/permissions")
            let perm = try JSONSerialization.jsonObject(with: requests[4].httpBody!) as! [String: String]
            #expect(perm == ["role": "reader", "type": "anyone"])
        }

        @Test func reusesExistingFolder() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 2)
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"files\":[{\"id\":\"old\"}]}".utf8)))
            StubURLProtocol.enqueue(
                .init(status: 200, headers: ["Location": "https://drive.example/session/2"]))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"id\":\"f\"}".utf8)))
            StubURLProtocol.enqueue(.init(status: 200, body: Data("{\"id\":\"p\"}".utf8)))
            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.link == URL(string: "https://drive.google.com/file/d/f/view"))
            let meta =
                try JSONSerialization.jsonObject(with: StubURLProtocol.requests[1].httpBody!)
                as! [String: Any]
            #expect(meta["parents"] as? [String] == ["old"])
        }

        @Test func missingScopeIsReported() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 2)
            let body = Data(
                "{\"error\":{\"code\":403,\"message\":\"Request had insufficient authentication scopes.\"}}"
                    .utf8)
            StubURLProtocol.enqueue(.init(status: 403, body: body))
            await #expect(throws: DriveError.insufficientScope) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }
    }
}
