import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct VimeoUploaderTests {
        static let uploadLink = "https://files.tus.vimeo.example/files/vimeo-video/123"
        static let created = Data(
            """
            {"uri":"/videos/123","link":"https://vimeo.com/123/abcdef","privacy":{"view":"unlisted"},\
            "upload":{"approach":"tus","upload_link":"\(uploadLink)","size":10}}
            """.utf8)

        func makeUploader(
            configuration: VimeoConfiguration? = VimeoConfiguration(token: "vtok", privacy: .unlisted),
            chunkSize: Int = 4, logs: LogLines = LogLines()
        ) -> VimeoUploader {
            StubURLProtocol.reset()
            return VimeoUploader(
                configuration: { configuration }, session: StubURLProtocol.makeSession(),
                chunkSize: chunkSize, sleep: { _ in }, log: { logs.append($0) })
        }

        func makeFile(bytes: Int) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appending(path: "vm-\(UUID().uuidString).mp4")
            var data = Data()
            for index in 0..<bytes { data.append(UInt8(index % 256)) }
            try data.write(to: url)
            return url
        }

        static func accepted(offset: Int) -> StubURLProtocol.Response {
            .init(status: 204, headers: ["Upload-Offset": String(offset), "Tus-Resumable": "1.0.0"])
        }

        @Test func createRequestCarriesTusSizeNameAndPrivacy() async throws {
            let uploader = makeUploader(
                configuration: VimeoConfiguration(token: "vtok", privacy: .nobody), chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))

            _ = try await uploader.upload(file: file, title: "Demo \"1\"") { _ in }

            let create = StubURLProtocol.requests[0]
            #expect(create.httpMethod == "POST")
            #expect(create.url?.absoluteString == "https://api.vimeo.com/me/videos")
            #expect(create.value(forHTTPHeaderField: "Authorization") == "bearer vtok")
            #expect(create.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(create.value(forHTTPHeaderField: "Accept") == "application/vnd.vimeo.*+json;version=3.4")
            let json = try JSONSerialization.jsonObject(with: create.httpBody!) as! [String: Any]
            let upload = json["upload"] as? [String: Any]
            #expect(upload?["approach"] as? String == "tus")
            #expect(upload?["size"] as? Int == 10)
            #expect(json["name"] as? String == "Demo \"1\"")
            #expect((json["privacy"] as? [String: Any])?["view"] as? String == "nobody")
        }

        @Test func twoChunkUploadSendsOffsetsAndBodies() async throws {
            let uploader = makeUploader(chunkSize: 6)
            let file = try makeFile(bytes: 10)
            let bytes = try Data(contentsOf: file)
            StubURLProtocol.enqueue(.init(status: 201, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 6))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))

            let progress = ProgressLog()
            let result = try await uploader.upload(file: file, title: "T") { progress.add($0) }

            let requests = StubURLProtocol.requests
            #expect(requests.count == 3)
            for (index, request) in requests.dropFirst().enumerated() {
                #expect(request.httpMethod == "PATCH")
                #expect(request.url?.absoluteString == Self.uploadLink)
                #expect(request.value(forHTTPHeaderField: "Tus-Resumable") == "1.0.0")
                #expect(
                    request.value(forHTTPHeaderField: "Content-Type") == "application/offset+octet-stream")
                #expect(request.value(forHTTPHeaderField: "Upload-Offset") == (index == 0 ? "0" : "6"))
            }
            #expect(requests[1].httpBody == bytes.prefix(6))
            #expect(requests[2].httpBody == bytes.suffix(4))
            #expect(progress.values.last == 1)
            #expect(progress.values == [0.6, 1.0])
            #expect(result.link == URL(string: "https://vimeo.com/123/abcdef"))
            #expect(result.videoID == "123")
            #expect(result.privacyStatus == "unlisted")
            #expect(result.isUnlisted)
        }

        @Test func serverErrorOnChunkTwoRecoversFromHeadOffset() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 10)
            let bytes = try Data(contentsOf: file)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 4))
            StubURLProtocol.enqueue(.init(status: 500))  // chunk 2 fails
            // HEAD: the server kept 6 of the 8 bytes sent so far.
            StubURLProtocol.enqueue(
                .init(status: 200, headers: ["Upload-Offset": "6", "Upload-Length": "10"]))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))

            let result = try await uploader.upload(file: file, title: "T") { _ in }

            let requests = StubURLProtocol.requests
            #expect(requests.count == 5)
            #expect(requests[3].httpMethod == "HEAD")
            #expect(requests[3].url?.absoluteString == Self.uploadLink)
            #expect(requests[3].value(forHTTPHeaderField: "Tus-Resumable") == "1.0.0")
            #expect(requests[4].httpMethod == "PATCH")
            #expect(requests[4].value(forHTTPHeaderField: "Upload-Offset") == "6")
            #expect(requests[4].httpBody == bytes.suffix(4))
            #expect(result.videoID == "123")
        }

        @Test func progressNeverGoesBackWhenHeadReportsFewerBytes() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 10)
            let bytes = try Data(contentsOf: file)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 4))
            StubURLProtocol.enqueue(Self.accepted(offset: 8))
            StubURLProtocol.enqueue(.init(status: 502))
            // The server dropped an uncommitted tail: only 6 bytes are kept.
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "6"]))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))

            let progress = ProgressLog()
            _ = try await uploader.upload(file: file, title: "T") { progress.add($0) }

            #expect(progress.values == progress.values.sorted())
            #expect(progress.values == [0.4, 0.8, 1.0])
            let requests = StubURLProtocol.requests
            #expect(requests[5].value(forHTTPHeaderField: "Upload-Offset") == "6")
            #expect(requests[5].httpBody == bytes.suffix(4))
        }

        @Test func conflictOnPatchResyncsThroughHead() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 8)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 4))
            StubURLProtocol.enqueue(.init(status: 409))
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "8"]))

            let progress = ProgressLog()
            let result = try await uploader.upload(file: file, title: "T") { progress.add($0) }
            #expect(result.videoID == "123")
            let requests = StubURLProtocol.requests
            #expect(requests.count == 4)
            #expect(requests[3].httpMethod == "HEAD")
            #expect(progress.values == [0.5, 1.0])
        }

        @Test func conflictsCountTowardTheRetryBound() async throws {
            let uploader = makeUploader(chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(.init(status: 409))
            for _ in 0..<3 {
                StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "0"]))
                StubURLProtocol.enqueue(.init(status: 409))
            }
            await #expect(throws: VimeoError.uploadIncomplete(offset: 0, size: 10)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.count == 8)
        }

        @Test func lowercaseUploadOffsetHeaderIsRead() async throws {
            let uploader = makeUploader(chunkSize: 6)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(.init(status: 204, headers: ["upload-offset": "6"]))
            StubURLProtocol.enqueue(.init(status: 500))
            StubURLProtocol.enqueue(.init(status: 200, headers: ["upload-offset": "10"]))

            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.videoID == "123")
            #expect(StubURLProtocol.requests.count == 4)
        }

        @Test func failingHeadEndsInUploadIncomplete() async throws {
            let uploader = makeUploader(chunkSize: 4)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 4))
            StubURLProtocol.enqueue(.init(status: 500))
            StubURLProtocol.enqueue(.init(status: 503))  // HEAD fails
            StubURLProtocol.enqueue(.init(status: 200))  // HEAD without Upload-Offset
            StubURLProtocol.enqueue(.init(status: 0, error: URLError(.timedOut)))  // HEAD fails
            await #expect(throws: VimeoError.uploadIncomplete(offset: 4, size: 10)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.count == 6)
        }

        @Test func networkErrorIsRetriedThroughHead() async throws {
            let uploader = makeUploader(chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(.init(status: 0, error: URLError(.networkConnectionLost)))
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "0"]))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))

            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.videoID == "123")
            #expect(StubURLProtocol.requests.count == 4)
        }

        @Test func headReportingCompletionFinishesTheUpload() async throws {
            let uploader = makeUploader(chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(.init(status: 503))
            StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "10"]))

            let progress = ProgressLog()
            let result = try await uploader.upload(file: file, title: "T") { progress.add($0) }
            #expect(result.videoID == "123")
            #expect(StubURLProtocol.requests.count == 3)
            #expect(progress.values.last == 1)
        }

        @Test func givesUpAfterThreeRetriesOnAChunk() async throws {
            let uploader = makeUploader(chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(.init(status: 500))
            for _ in 0..<3 {
                StubURLProtocol.enqueue(.init(status: 200, headers: ["Upload-Offset": "0"]))
                StubURLProtocol.enqueue(.init(status: 500))
            }
            await #expect(throws: VimeoError.uploadIncomplete(offset: 0, size: 10)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            // Create, the first PATCH, then three HEAD + PATCH retries.
            #expect(StubURLProtocol.requests.count == 8)
        }

        @Test func apiErrorSurfacesTheMessage() async throws {
            let logs = LogLines()
            let uploader = makeUploader(logs: logs)
            let file = try makeFile(bytes: 10)
            let body = Data(
                """
                {"error":"You have exceeded your upload quota.","developer_message":"Quota exceeded.",\
                "error_code":4102}
                """.utf8)
            StubURLProtocol.enqueue(.init(status: 400, body: body))
            await #expect(
                throws: VimeoError.apiError(status: 400, message: "You have exceeded your upload quota.")
            ) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.count == 1)
            #expect(logs.all.contains { $0.contains("HTTP 400") })
            #expect(!logs.all.contains { $0.contains("vtok") })
        }

        @Test func developerMessageIsUsedWithoutAnError() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(
                .init(status: 403, body: Data(#"{"developer_message":"No upload scope"}"#.utf8)))
            await #expect(throws: VimeoError.apiError(status: 403, message: "No upload scope")) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func nonJSONErrorFallsBackToTheStatus() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 401, body: Data("nope".utf8)))
            await #expect(throws: VimeoError.apiError(status: 401, message: "HTTP 401")) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func missingConfigurationIsNotConfigured() async throws {
            let uploader = makeUploader(configuration: nil)
            let file = try makeFile(bytes: 10)
            await #expect(throws: VimeoError.notConfigured) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func emptyTokenIsNotConfigured() async throws {
            let uploader = makeUploader(configuration: VimeoConfiguration(token: "  ", privacy: .unlisted))
            let file = try makeFile(bytes: 10)
            await #expect(throws: VimeoError.notConfigured) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
        }

        @Test func createResponseWithoutUploadLinkIsBad() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Data(#"{"uri":"/videos/1"}"#.utf8)))
            await #expect(throws: VimeoError.badResponse(200)) {
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

        @Test func reportsTheUploadingStage() async throws {
            let uploader = makeUploader(chunkSize: 16)
            let file = try makeFile(bytes: 10)
            StubURLProtocol.enqueue(.init(status: 200, body: Self.created))
            StubURLProtocol.enqueue(Self.accepted(offset: 10))
            let stages = LogLines()
            _ = try await uploader.upload(
                file: file, title: "T", context: UploadContext(onStatus: { stages.append($0) })
            ) { _ in }
            #expect(stages.all == ["Uploading"])
        }
    }
}

@Suite struct VimeoValueTests {
    @Test func privacyRawValuesMatchTheAPI() {
        #expect(VimeoPrivacy.unlisted.rawValue == "unlisted")
        #expect(VimeoPrivacy.anybody.rawValue == "anybody")
        #expect(VimeoPrivacy.nobody.rawValue == "nobody")
        #expect(VimeoPrivacy.allCases == [.unlisted, .anybody, .nobody])
        #expect(VimeoPrivacy.unlisted.label == "Unlisted")
        #expect(VimeoPrivacy.anybody.label == "Public")
        #expect(VimeoPrivacy.nobody.label == "Only me")
    }

    @Test func redactHidesTheBearerToken() {
        #expect(
            VimeoUploader.redact("Authorization: bearer 0123abcDEF_xyz-9 sent")
                == "Authorization: bearer <redacted> sent")
        #expect(VimeoUploader.redact("Bearer abc") == "bearer <redacted>")
        #expect(VimeoUploader.redact("no token here") == "no token here")
    }

    @Test func vimeoResultsDoNotWarnAboutPrivacy() {
        for privacy in VimeoPrivacy.allCases {
            let result = UploadResult(
                link: URL(string: "https://vimeo.com/1")!, videoID: "1", privacyStatus: privacy.rawValue)
            #expect(result.isUnlisted)
        }
        #expect(UploadResult(videoID: "p", privacyStatus: "private").isUnlisted == false)
    }
}
