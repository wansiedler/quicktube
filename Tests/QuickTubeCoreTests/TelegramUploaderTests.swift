import Foundation
import QuickTubeCore
import Testing

extension NetworkSuite {
    @Suite struct TelegramUploaderTests {
        let store = InMemorySecretStore()

        func makeUploader(
            limitBytes: Int = TelegramUploader.botAPILimit,
            compressToFit: Bool = true,
            allowDownscale: Bool = false,
            videoInfo: @escaping @Sendable (URL) async throws -> VideoInfo = {
                _ in throw VideoInfo.ReadError.noVideoTrack
            },
            transcode: @escaping TelegramUploader.Transcode = { _, _, _, _ in
                Issue.record("transcode must not run")
                throw TranscodeError.failed("unexpected")
            }
        ) -> TelegramUploader {
            StubURLProtocol.reset()
            return TelegramUploader(
                store: store, session: StubURLProtocol.makeSession(),
                baseURL: URL(string: "https://tg.example")!, limitBytes: { limitBytes },
                compressToFit: { compressToFit }, allowDownscale: { allowDownscale }, videoInfo: videoInfo,
                transcode: transcode)
        }

        /// A transcode stub that writes `bytes` bytes of 0xEE to the requested output.
        func fakeTranscode(bytes: Int, calls: TranscodeCalls) -> TelegramUploader.Transcode {
            { input, plan, output, progress in
                calls.add(input: input, plan: plan, output: output)
                try Data(repeating: 0xEE, count: bytes).write(to: output)
                progress(0.5)
                progress(1)
                return output
            }
        }

        static let info = VideoInfo(width: 2560, height: 1440, fps: 60, duration: 60)

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

        @Test func redactReplacesTheBotTokenInURLs() {
            let text =
                "NSErrorFailingURLStringKey=https://api.telegram.org/bot123456789:AAH-x_Yz09/sendVideo, code -1009"
            let redacted = TelegramUploader.redact(text)
            #expect(redacted.contains("https://api.telegram.org/bot<redacted>/sendVideo"))
            #expect(!redacted.contains("123456789"))
            #expect(!redacted.contains("AAH-x_Yz09"))
            #expect(TelegramUploader.redact("plain text, no token") == "plain text, no token")
        }

        @MainActor @Test func transportFailureDoesNotLeakTheToken() async throws {
            let token = "987654321:SECRET-token_value"
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: token, chat: "@c"))
            let file = try makeFile(bytes: 16)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue { request in
                let url = request.url!
                return .init(
                    status: 0,
                    error: URLError(
                        .notConnectedToInternet,
                        userInfo: [
                            NSURLErrorFailingURLErrorKey: url,
                            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                        ]))
            }

            var thrown: Error?
            do {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            } catch {
                thrown = error
            }
            let error = try #require(thrown)
            guard case TelegramError.network = error else {
                Issue.record("expected TelegramError.network, got \(error)")
                return
            }
            #expect(!"\(error)".contains("SECRET"))
            #expect(!String(describing: error).contains("987654321"))
            let message = AppState.message(for: error, stage: .upload)
            #expect(message.hasPrefix("Could not reach Telegram: "))
            #expect(!message.contains("SECRET"))
        }

        @MainActor @Test func fallbackMessageRedactsTokens() {
            let url = URL(string: "https://api.telegram.org/bot1:abc_DEF/sendVideo")!
            let error = URLError(
                .timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
            let message = AppState.message(for: error, stage: .upload)
            #expect(message.hasPrefix("Upload failed: "))
            #expect(!message.contains("abc_DEF"))
        }

        @Test func captionCarriesTheMetadataLine() async throws {
            let uploader = makeUploader(videoInfo: { _ in
                VideoInfo(width: 2560, height: 1440, fps: 60, duration: 3)
            })
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 3 * 1_048_576)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            _ = try await uploader.upload(
                file: file, title: "Demo", context: UploadContext(display: "Studio Display")
            ) { _ in }
            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(
                body.contains(
                    "name=\"caption\"\r\n\r\nDemo\nStudio Display · 2560×1440 · 60 fps · 3 MB\r\n"))
        }

        @Test func unreadableVideoKeepsPlainTitleCaption() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            _ = try await uploader.upload(file: file, title: "Demo") { _ in }
            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("name=\"caption\"\r\n\r\nDemo\r\n"))
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

        @Test func privateChatUsesDeepLink() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "4242"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "alex", id: 4242, messageID: 9)))
            let result = try await uploader.upload(file: file, title: "T") { _ in }
            #expect(result.link == URL(string: "tg://openmessage?user_id=4242&message_id=9"))
        }

        @Test func missingConfigurationIsReported() async throws {
            let uploader = makeUploader()
            let file = try makeFile(bytes: 4)
            await #expect(throws: TelegramError.notConfigured) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func oversizedFileIsRejectedWhenCompressionIsOff() async throws {
            let uploader = makeUploader(limitBytes: 10, compressToFit: false)
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 11)
            await #expect(throws: TelegramError.fileTooLarge(limit: 10, actual: 11)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func downscaleSettingIsPassedToThePlan() async throws {
            let calls = TranscodeCalls()
            let uploader = makeUploader(
                limitBytes: 100, allowDownscale: true, videoInfo: { _ in Self.info },
                transcode: fakeTranscode(bytes: 60, calls: calls))
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))

            _ = try await uploader.upload(file: file, title: "T") { _ in }

            let call = try #require(calls.all.first)
            #expect(call.plan == VideoTranscoder.plan(info: Self.info, limitBytes: 100, allowDownscale: true))
            #expect(call.plan != VideoTranscoder.plan(info: Self.info, limitBytes: 100))
        }

        @Test func oversizedFileIsTranscodedAndTheCopySent() async throws {
            let calls = TranscodeCalls()
            let uploader = makeUploader(
                limitBytes: 100, videoInfo: { _ in Self.info },
                transcode: fakeTranscode(bytes: 60, calls: calls))
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            let seen = ProgressLog()

            _ = try await uploader.upload(file: file, title: "T") { seen.add($0) }

            let call = try #require(calls.all.first)
            #expect(calls.all.count == 1)
            #expect(call.input == file)
            #expect(call.plan == VideoTranscoder.plan(info: Self.info, limitBytes: 100))
            let stem = file.deletingPathExtension().lastPathComponent
            #expect(call.output.lastPathComponent == "\(stem).telegram.mp4")
            #expect(call.output.deletingLastPathComponent() == file.deletingLastPathComponent())
            let body = StubURLProtocol.requests[0].httpBody ?? Data()
            #expect(String(decoding: body, as: UTF8.self).contains("filename=\"\(stem).telegram.mp4\""))
            #expect(body.contains(Data(repeating: 0xEE, count: 60)))
            #expect(!body.contains(Data(repeating: 0xCD, count: 200)))
            #expect(!FileManager.default.fileExists(atPath: call.output.path))
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(seen.values == [0, 0.5, 1, 0, 1])
        }

        @Test func directUploadSendsDimensionsOfTheOriginal() async throws {
            let asked = AskedURLs()
            let uploader = makeUploader(
                limitBytes: 100,
                videoInfo: { url in
                    asked.add(url)
                    return VideoInfo(width: 2560, height: 1440, fps: 60, duration: 12.6)
                })
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 50)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))

            _ = try await uploader.upload(file: file, title: "T") { _ in }

            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("name=\"width\"\r\n\r\n2560\r\n"))
            #expect(body.contains("name=\"height\"\r\n\r\n1440\r\n"))
            #expect(body.contains("name=\"duration\"\r\n\r\n13\r\n"))
            #expect(asked.all == [file])
        }

        @Test func transcodingReportsCompressingThenUploading() async throws {
            let statuses = AskedStrings()
            let uploader = makeUploader(
                limitBytes: 100 << 20,
                videoInfo: { _ in VideoInfo(width: 2560, height: 1440, fps: 60, duration: 60) },
                transcode: fakeTranscode(bytes: 60, calls: TranscodeCalls()))
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200 << 20)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))

            _ = try await uploader.upload(
                file: file, title: "T", context: UploadContext(onStatus: { statuses.add($0) })
            ) { _ in }

            let all = statuses.all
            #expect(all.count == 2)
            #expect(all[0].hasPrefix("Compressing · 2560×1440 60 fps 200 MB → "))
            #expect(all[0].hasSuffix(" fps ~100 MB"))
            #expect(all.last == "Uploading")
        }

        @Test func plainUploadReportsOnlyUploading() async throws {
            let statuses = AskedStrings()
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            _ = try await uploader.upload(
                file: file, title: "T", context: UploadContext(onStatus: { statuses.add($0) })
            ) { _ in }
            #expect(statuses.all == ["Uploading"])
        }

        @Test func transcodedUploadSendsDimensionsOfTheTranscodedCopy() async throws {
            let asked = AskedURLs()
            let calls = TranscodeCalls()
            let original = VideoInfo(width: 2560, height: 1440, fps: 60, duration: 60)
            let uploader = makeUploader(
                limitBytes: 100,
                videoInfo: { url in
                    asked.add(url)
                    return url.lastPathComponent.hasSuffix(".telegram.mp4")
                        ? VideoInfo(width: 1280, height: 720, fps: 30, duration: 59.6) : original
                },
                transcode: fakeTranscode(bytes: 60, calls: calls))
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))

            _ = try await uploader.upload(
                file: file, title: "T", context: UploadContext(display: "Display")
            ) { _ in }

            let output = try #require(calls.all.first).output
            #expect(asked.all == [file, output])
            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("name=\"width\"\r\n\r\n1280\r\n"))
            #expect(body.contains("name=\"height\"\r\n\r\n720\r\n"))
            #expect(body.contains("name=\"duration\"\r\n\r\n60\r\n"))
            // The caption still describes the original recording.
            #expect(body.contains("Display · 2560×1440 · 60 fps"))
        }

        @Test func unreadableVideoOmitsDimensions() async throws {
            let uploader = makeUploader()
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 4)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            _ = try await uploader.upload(file: file, title: "T") { _ in }
            let body = String(decoding: StubURLProtocol.requests[0].httpBody ?? Data(), as: UTF8.self)
            #expect(!body.contains("name=\"width\""))
        }

        @Test func fileUnderTheLimitIsNotTranscoded() async throws {
            let uploader = makeUploader(limitBytes: 100, videoInfo: { _ in Self.info })
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 100)
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))
            _ = try await uploader.upload(file: file, title: "T") { _ in }
            let body = StubURLProtocol.requests[0].httpBody ?? Data()
            #expect(body.contains(Data(repeating: 0xCD, count: 100)))
        }

        @Test func transcodedFileStillTooLargeIsRejected() async throws {
            let calls = TranscodeCalls()
            let uploader = makeUploader(
                limitBytes: 100, videoInfo: { _ in Self.info },
                transcode: fakeTranscode(bytes: 150, calls: calls))
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200)
            await #expect(throws: TelegramError.fileTooLarge(limit: 100, actual: 150)) {
                _ = try await uploader.upload(file: file, title: "T") { _ in }
            }
            #expect(StubURLProtocol.requests.isEmpty)
            #expect(calls.all.count == 2)
            let output = try #require(calls.all.first?.output)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }

        @Test func oversizedTranscodeIsRetriedOnceAtALowerBitrate() async throws {
            let calls = TranscodeCalls()
            let info = VideoInfo(width: 6016, height: 3384, fps: 60, duration: 10)
            let statuses = AskedStrings()
            let seen = ProgressLog()
            let limit = 10 << 20
            let uploader = makeUploader(
                limitBytes: limit, videoInfo: { _ in info },
                transcode: { input, plan, output, progress in
                    calls.add(input: input, plan: plan, output: output)
                    let bytes = calls.all.count == 1 ? 13 << 20 : 9 << 20
                    try Data(repeating: 0xEE, count: bytes).write(to: output)
                    progress(1)
                    return output
                })
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 20 * 1_048_576)
            defer { try? FileManager.default.removeItem(at: file) }
            StubURLProtocol.enqueue(.init(status: 200, body: reply(username: "c", id: -1001, messageID: 1)))

            _ = try await uploader.upload(
                file: file, title: "T", context: UploadContext(onStatus: { statuses.add($0) })
            ) { seen.add($0) }

            let all = calls.all
            #expect(all.count == 2)
            let first = all[0].plan
            let second = all[1].plan
            #expect(second.videoBitrate < first.videoBitrate)
            #expect(
                second == TelegramUploader.retryPlan(after: first, actualBytes: 13 << 20, limitBytes: limit))
            #expect(second.width == first.width && second.audioBitrate == first.audioBitrate)
            #expect(statuses.all.count == 3)
            #expect(statuses.all[0].hasPrefix("Compressing · "))
            #expect(statuses.all[1].hasPrefix("Compressing again · "))
            #expect(statuses.all.last == "Uploading")
            #expect(seen.values.prefix(4) == [0, 1, 0, 1])
            #expect(StubURLProtocol.requests.count == 1)
        }

        @Test func retryPlanScalesTheVideoBitrateAndKeepsTheFloor() {
            let plan = TranscodePlan(
                width: 6016, height: 3384, videoBitrate: 2_690_000, audioBitrate: 160_000)
            let retry = TelegramUploader.retryPlan(after: plan, actualBytes: 66 << 20, limitBytes: 50 << 20)
            #expect(retry.videoBitrate == Int(2_690_000.0 * 50 / 66 * 0.9))
            #expect(retry.width == 6016 && retry.height == 3384 && retry.audioBitrate == 160_000)
            let tiny = TranscodePlan(width: 640, height: 360, videoBitrate: 160_000, audioBitrate: 0)
            #expect(
                TelegramUploader.retryPlan(after: tiny, actualBytes: 1000, limitBytes: 100).videoBitrate
                    == VideoTranscoder.minimumVideoBitrate)
        }

        @Test func oversizedUnreadableVideoCannotBeTranscoded() async throws {
            let uploader = makeUploader(limitBytes: 100)
            try await uploader.setConfiguration(TelegramConfiguration(botToken: "t", chat: "@c"))
            let file = try makeFile(bytes: 200)
            await #expect(throws: TranscodeError.cannotRead) {
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

final class TranscodeCalls: @unchecked Sendable {
    struct Call {
        let input: URL
        let plan: TranscodePlan
        let output: URL
    }
    private let lock = NSLock()
    private var stored: [Call] = []
    var all: [Call] { lock.withLock { stored } }
    func add(input: URL, plan: TranscodePlan, output: URL) {
        lock.withLock { stored.append(Call(input: input, plan: plan, output: output)) }
    }
}

final class AskedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var all: [URL] { lock.withLock { stored } }
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
}

final class AskedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { lock.withLock { stored.append(value) } }
    var all: [String] { lock.withLock { stored } }
}
