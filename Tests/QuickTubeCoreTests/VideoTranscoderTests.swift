import AVFoundation
import Foundation
import QuickTubeCore
import Testing
import VideoToolbox

@Suite struct VideoTranscoderTests {
    static let fiftyMB = 50 << 20

    @Test func bitratesFillTheLimitWithHeadroom() {
        let info = VideoInfo(width: 2560, height: 1440, fps: 60, duration: 60)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB)
        let budget = Double(Self.fiftyMB) * 8 * 0.92
        let used = Double(plan.videoBitrate + plan.audioBitrate) * 60
        #expect(used <= budget)
        #expect(used > budget - 60 * 2)
        #expect(plan.audioBitrate == 160_000)
    }

    @Test func audioStrategyPassesOneTrackThroughAndMixesSeveral() {
        #expect(VideoTranscoder.audioStrategy(trackCount: 0, estimatedDataRate: nil) == .none)
        #expect(VideoTranscoder.audioStrategy(trackCount: 0, estimatedDataRate: 128_000) == .none)
        #expect(
            VideoTranscoder.audioStrategy(trackCount: 1, estimatedDataRate: 191_999.4)
                == .passthrough(bitrate: 192_000))
        #expect(
            VideoTranscoder.audioStrategy(trackCount: 2, estimatedDataRate: nil) == .mix(bitrate: 160_000))
        #expect(
            VideoTranscoder.audioStrategy(trackCount: 3, estimatedDataRate: 64_000) == .mix(bitrate: 160_000))
        #expect(
            VideoTranscoder.audioStrategy(trackCount: 1, estimatedDataRate: 128_000, canPassThrough: false)
                == .mix(bitrate: 160_000))
        #expect(AudioStrategy.none.bitrate == 0)
        #expect(AudioStrategy.passthrough(bitrate: 5).bitrate == 5)
        #expect(AudioStrategy.mix(bitrate: 7).bitrate == 7)
    }

    @Test func audioStrategyFallsBackTo160kWhenTheRateIsUnknown() {
        for rate: Float? in [nil, 0, -1, .nan, .infinity] {
            #expect(
                VideoTranscoder.audioStrategy(trackCount: 1, estimatedDataRate: rate)
                    == .passthrough(bitrate: 160_000))
        }
    }

    @Test func planBudgetsTheAudioByStrategy() {
        func plan(_ count: Int?, _ rate: Float?, audioBitrate: Int? = nil) -> TranscodePlan {
            let info = VideoInfo(
                width: 1920, height: 1080, fps: 30, duration: 60, audioTrackCount: count, audioDataRate: rate)
            return VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, audioBitrate: audioBitrate)
        }
        let total = Int((Double(Self.fiftyMB) * 8 * 0.92 / 60).rounded(.down))
        #expect(plan(nil, nil).audioBitrate == 160_000)
        #expect(plan(0, nil).audioBitrate == 0)
        #expect(plan(0, nil).videoBitrate == total)
        #expect(plan(1, 256_000).audioBitrate == 256_000)
        #expect(plan(1, 256_000).videoBitrate == total - 256_000)
        #expect(plan(1, nil).audioBitrate == 160_000)
        #expect(plan(2, nil).audioBitrate == 160_000)
        #expect(plan(2, nil, audioBitrate: 96_000).audioBitrate == 96_000)
    }

    @Test func keepsNaturalSizeWhenBitsPerPixelSuffice() {
        let info = VideoInfo(width: 2560, height: 1440, fps: 60, duration: 10)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB)
        #expect(plan.width == 2560 && plan.height == 1440)
    }

    @Test func stepsDownTheLongSideWhenBitsPerPixelTooLow() {
        // 60 s at 60 fps: ~6.3 Mbit/s is 0.05 bit/pixel/frame at 1080p, 0.11 at 720p.
        let info = VideoInfo(width: 2560, height: 1440, fps: 60, duration: 60)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(plan.width == 1280 && plan.height == 720)
    }

    @Test func portraitStepsDownTheHeight() {
        let info = VideoInfo(width: 1440, height: 2560, fps: 60, duration: 60)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(plan.width == 720 && plan.height == 1280)
    }

    @Test func stopsAt640WhenNothingIsEnough() {
        let info = VideoInfo(width: 3840, height: 2160, fps: 60, duration: 1800)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(plan.width == 640 && plan.height == 360)
    }

    @Test func neverUpscales() {
        let small = VideoInfo(width: 600, height: 400, fps: 60, duration: 3600)
        let plan = VideoTranscoder.plan(info: small, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(plan.width == 600 && plan.height == 400)
        // Only steps below the natural long side are considered.
        let mid = VideoInfo(width: 1100, height: 700, fps: 60, duration: 3600)
        let midPlan = VideoTranscoder.plan(info: mid, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(midPlan.width == 640 && midPlan.height == 408)
    }

    @Test func dimensionsAreEven() {
        let info = VideoInfo(width: 1366, height: 769, fps: 30, duration: 600)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, allowDownscale: true)
        #expect(plan.width % 2 == 0 && plan.height % 2 == 0)
        let odd = VideoInfo(width: 1001, height: 777, fps: 30, duration: 1)
        let oddPlan = VideoTranscoder.plan(info: odd, limitBytes: Self.fiftyMB)
        #expect(oddPlan.width == 1000 && oddPlan.height == 776)
    }

    @Test func compressionPropertiesPreferSpeedAndSkipReordering() throws {
        let properties = VideoTranscoder.compressionProperties(bitrate: 2_000_000, fps: 29.97, hardware: true)
        #expect(properties[AVVideoAverageBitRateKey] as? Int == 2_000_000)
        #expect(properties[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(
            properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] as? Bool
                == true)
        #expect(properties[AVVideoExpectedSourceFrameRateKey] as? Int == 30)
        let limits = try #require(
            properties[kVTCompressionPropertyKey_DataRateLimits as String] as? [NSNumber])
        #expect(limits == [NSNumber(value: 250_000), NSNumber(value: 1.0)])
        let unknownFPS = VideoTranscoder.compressionProperties(bitrate: 1, fps: 0, hardware: true)
        #expect(unknownFPS[AVVideoExpectedSourceFrameRateKey] == nil)
    }

    @Test func softwareCompressionPropertiesHaveNoDataRateLimits() {
        // Apple's software HEVC encoder raises NSInvalidArgumentException on these VideoToolbox keys.
        let properties = VideoTranscoder.compressionProperties(bitrate: 2_000_000, fps: 30, hardware: false)
        #expect(properties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect(properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] == nil)
        #expect(properties[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(properties[AVVideoExpectedSourceFrameRateKey] as? Int == 30)
        #expect(properties[AVVideoAverageBitRateKey] as? Int == 2_000_000)
    }

    @Test func encoderUnavailableIsRecognisedThroughUnderlyingErrors() {
        func wrapped(_ domain: String, _ code: Int) -> NSError {
            NSError(
                domain: AVFoundationErrorDomain, code: -11800,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: domain, code: code)])
        }
        #expect(VideoTranscoder.isEncoderUnavailable(wrapped(NSOSStatusErrorDomain, -12903)))
        #expect(VideoTranscoder.isEncoderUnavailable(wrapped(NSOSStatusErrorDomain, -12908)))
        #expect(VideoTranscoder.isEncoderUnavailable(wrapped(NSOSStatusErrorDomain, -12915)))
        #expect(VideoTranscoder.isEncoderUnavailable(wrapped(NSOSStatusErrorDomain, -12907)))
        #expect(
            VideoTranscoder.isEncoderUnavailable(
                NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderNotFound.rawValue)))
        #expect(!VideoTranscoder.isEncoderUnavailable(nil))
        #expect(!VideoTranscoder.isEncoderUnavailable(wrapped(NSPOSIXErrorDomain, 28)))  // disk full
        #expect(!VideoTranscoder.isEncoderUnavailable(wrapped(NSCocoaErrorDomain, -12908)))
        #expect(!VideoTranscoder.isEncoderUnavailable(NSError(domain: AVFoundationErrorDomain, code: -11800)))
    }

    @Test func onlyTheHardwareAttemptRetriesInSoftware() {
        let unavailable = NSError(
            domain: AVFoundationErrorDomain, code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12908)])
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: 28)
        // The writer rejecting the hardware settings retries once in software.
        #expect(VideoTranscoder.shouldRetryInSoftware(hardware: true, inputRejected: true, error: nil))
        #expect(
            VideoTranscoder.shouldRetryInSoftware(hardware: true, inputRejected: false, error: unavailable))
        #expect(!VideoTranscoder.shouldRetryInSoftware(hardware: true, inputRejected: false, error: diskFull))
        #expect(!VideoTranscoder.shouldRetryInSoftware(hardware: true, inputRejected: false, error: nil))
        // The software attempt never retries: its failures are final.
        #expect(!VideoTranscoder.shouldRetryInSoftware(hardware: false, inputRejected: true, error: nil))
        #expect(
            !VideoTranscoder.shouldRetryInSoftware(hardware: false, inputRejected: false, error: unavailable))
    }

    @Test func encoderSpecificationRequiresTheHardwareEncoder() {
        let specification = VideoTranscoder.encoderSpecification()
        #expect(
            specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String]
                as? Bool
                == true)
        #expect(
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String]
                as? Bool
                == true)
    }

    @Test func throughputLineReportsFramesSecondsAndFPS() {
        #expect(
            VideoTranscoder.throughputLine(frames: 2640, seconds: 61.24)
                == "transcoded 2640 frames in 61.2 s (43 fps)")
        #expect(
            VideoTranscoder.throughputLine(frames: 5, seconds: 0) == "transcoded 5 frames in 0.0 s (0 fps)")
    }

    @Test func clampsTheMinimumVideoBitrate() {
        let info = VideoInfo(width: 1920, height: 1080, fps: 30, duration: 3600)
        let plan = VideoTranscoder.plan(info: info, limitBytes: 1 << 20)
        #expect(plan.videoBitrate == 150_000)
    }

    @Test func keepsNaturalSizeByDefaultEvenWhenBitsPerPixelIsTiny() {
        let info = VideoInfo(width: 3840, height: 2160, fps: 60, duration: 1800)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB)
        #expect(plan.width == 3840 && plan.height == 2160)
        #expect(plan == VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB, allowDownscale: false))
        let odd = VideoInfo(width: 1001, height: 777, fps: 60, duration: 3600)
        let oddPlan = VideoTranscoder.plan(info: odd, limitBytes: Self.fiftyMB)
        #expect(oddPlan.width == 1000 && oddPlan.height == 776)
    }

    @Test func missingFrameRateAssumes30AndZeroDurationIsSafe() {
        let info = VideoInfo(width: 1920, height: 1080, fps: nil, duration: 0)
        let plan = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB)
        #expect(plan.videoBitrate > 300_000)
        #expect(plan.width == 1920 && plan.height == 1080)
    }

    // MARK: - Mobile-friendly (H.264, up to 1080p)

    @Test func mobileSizeCapsTheLongSideKeepingAspect() {
        func size(_ w: Int, _ h: Int, _ cap: Int = 1920) -> [Int] {
            let (width, height) = VideoTranscoder.mobileSize(
                for: VideoInfo(width: w, height: h, fps: 30, duration: 1), maxLongSide: cap)
            return [width, height]
        }
        #expect(size(6016, 3384) == [1920, 1080])
        #expect(size(3840, 2160) == [1920, 1080])
        #expect(size(1280, 720) == [1280, 720])
        #expect(size(1080, 1920) == [1080, 1920])
        #expect(size(2160, 3840) == [1080, 1920])
        #expect(size(1281, 721) == [1280, 720])
        // 2000×1001 → 1920×960.96: rounded to an even 960.
        #expect(size(2000, 1001) == [1920, 960])
        #expect(size(2000, 1001).allSatisfy { $0 % 2 == 0 })
    }

    @Test func h264PlanUsesTheCapAndFitsTheLimit() {
        let info = VideoInfo(width: 6016, height: 3384, fps: 45, duration: 60, audioTrackCount: 0)
        let plan = VideoTranscoder.plan(
            info: info, limitBytes: Self.fiftyMB, maxLongSide: 1920, codec: .h264)
        #expect(plan.codec == .h264)
        #expect(plan.width == 1920 && plan.height == 1080)
        // The bitrate budget is the same as for the uncapped plan: only the size changes.
        let uncapped = VideoTranscoder.plan(info: info, limitBytes: Self.fiftyMB)
        #expect(plan.videoBitrate == uncapped.videoBitrate)
        #expect(uncapped.codec == .hevc)
        let small = VideoTranscoder.plan(
            info: VideoInfo(width: 1280, height: 720, fps: 30, duration: 60), limitBytes: Self.fiftyMB,
            maxLongSide: 1920, codec: .h264)
        #expect(small.width == 1280 && small.height == 720)
    }

    @Test func h264BitrateIsCappedForShortClips() {
        let six = VideoInfo(width: 6016, height: 3384, fps: 45, duration: 10, audioTrackCount: 0)
        let fast = VideoTranscoder.plan(info: six, limitBytes: Self.fiftyMB, maxLongSide: 1920, codec: .h264)
        #expect(fast.width == 1920 && fast.height == 1080)
        #expect(fast.videoBitrate == 16_000_000)
        let thirty = VideoInfo(width: 6016, height: 3384, fps: 30, duration: 10, audioTrackCount: 0)
        let slow = VideoTranscoder.plan(
            info: thirty, limitBytes: Self.fiftyMB, maxLongSide: 1920, codec: .h264)
        #expect(slow.videoBitrate == 12_000_000)
        // HEVC keeps filling the limit.
        let hevc = VideoTranscoder.plan(info: six, limitBytes: Self.fiftyMB)
        #expect(hevc.videoBitrate > 30_000_000)
        // A long recording is below the cap and unchanged.
        let long = VideoInfo(width: 6016, height: 3384, fps: 45, duration: 60, audioTrackCount: 0)
        let longH264 = VideoTranscoder.plan(
            info: long, limitBytes: Self.fiftyMB, maxLongSide: 1920, codec: .h264)
        #expect(
            longH264.videoBitrate == VideoTranscoder.plan(info: long, limitBytes: Self.fiftyMB).videoBitrate)
        // The cap is applied after the size is chosen, so it never forces a downscale step.
        let sixty = VideoInfo(width: 1920, height: 1080, fps: 60, duration: 10, audioTrackCount: 0)
        let kept = VideoTranscoder.plan(
            info: sixty, limitBytes: Self.fiftyMB, allowDownscale: true, maxLongSide: 1920, codec: .h264)
        #expect(kept.width == 1920 && kept.height == 1080)
        #expect(kept.videoBitrate == 16_000_000)
    }

    @Test func h264BitrateCapScalesWithThePixelCount() {
        #expect(VideoTranscoder.h264BitrateCap(width: 1920, height: 1080, fps: 30) == 12_000_000)
        #expect(VideoTranscoder.h264BitrateCap(width: 1920, height: 1080, fps: 60) == 16_000_000)
        #expect(VideoTranscoder.h264BitrateCap(width: 1280, height: 720, fps: 30) == 5_333_333)
        #expect(VideoTranscoder.h264BitrateCap(width: 1080, height: 1920, fps: 30) == 12_000_000)
        #expect(
            VideoTranscoder.h264BitrateCap(width: 64, height: 36, fps: 30)
                == VideoTranscoder.minimumVideoBitrate)
    }

    @Test func h264CompressionPropertiesUseHighProfile() {
        let hardware = VideoTranscoder.compressionProperties(
            bitrate: 4_000_000, fps: 45, hardware: true, codec: .h264)
        #expect(hardware[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
        #expect(hardware[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(hardware[kVTCompressionPropertyKey_DataRateLimits as String] != nil)
        let software = VideoTranscoder.compressionProperties(
            bitrate: 4_000_000, fps: 45, hardware: false, codec: .h264)
        #expect(software[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
        #expect(software[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect(software[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] == nil)
        let hevc = VideoTranscoder.compressionProperties(bitrate: 4_000_000, fps: 45, hardware: true)
        #expect(hevc[AVVideoProfileLevelKey] == nil)
    }

    @Test func throughputLineNamesTheCodecAndSize() {
        let plan = TranscodePlan(
            width: 1920, height: 1080, videoBitrate: 1, audioBitrate: 1, codec: .h264)
        #expect(
            VideoTranscoder.throughputLine(frames: 90, seconds: 3, plan: plan)
                == "transcoded 90 frames in 3.0 s (30 fps), h264 1920×1080")
    }

    // MARK: - End to end

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func transcodesAGeneratedClip() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 64_000)
        let output = dir.appending(path: "clip.telegram.mp4")
        let seen = ProgressLog()
        let logged = AskedStrings()
        let result = try await VideoTranscoder.transcode(
            input, plan: plan, output: output, log: { logged.add($0) }
        ) { seen.add($0) }
        let throughput = try #require(logged.all.last)
        #expect(throughput.hasPrefix("transcoded 30 frames in "))

        #expect(result == output)
        let info = try await VideoInfo.read(output)
        #expect(info.width == 320 && info.height == 240)
        #expect(abs(info.duration - 1) < 0.2)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).isEmpty)
        let values = seen.values
        #expect(!values.isEmpty)
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func keepsTheNaturalLandscapeSize() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "wide.mov")
        try await ClipMaker.make(input, width: 640, height: 360, fps: 30, seconds: 1)
        let sourceInfo = try await VideoInfo.read(input)
        let plan = VideoTranscoder.plan(info: sourceInfo, limitBytes: Self.fiftyMB, allowDownscale: false)
        #expect(plan.width == 640 && plan.height == 360)
        let output = dir.appending(path: "wide.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in }

        let info = try await VideoInfo.read(output)
        #expect(info.width == 640 && info.height == 360)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func scalesToThePlanSizeForADifferentAspect() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "boxy.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1)
        // Bars versus stretch is not checkable here; the output must have exactly the plan size.
        let plan = TranscodePlan(width: 640, height: 360, videoBitrate: 300_000, audioBitrate: 64_000)
        let output = dir.appending(path: "boxy.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in }

        let info = try await VideoInfo.read(output)
        #expect(info.width == 640 && info.height == 360)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func keepsTheAudioTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1, audio: true)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 64_000)
        let output = dir.appending(path: "clip.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in }

        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.contains { $0.mediaType == .video })
        let audio = try #require(tracks.first { $0.mediaType == .audio })
        let formats = try await audio.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func passesASingleAACTrackThroughUntouched() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 2, audio: true)
        let sourceInfo = try await VideoInfo.read(input)
        #expect(sourceInfo.audioTrackCount == 1)
        let sourceRate = try #require(sourceInfo.audioDataRate)
        #expect(sourceRate > 0)
        let sourceTrack = try #require(
            try await AVURLAsset(url: input).loadTracks(withMediaType: .audio).first)
        let sourceFormat = try #require(try await sourceTrack.load(.formatDescriptions).first)
        let sourceASBD = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee)
        let limit = 1 << 20
        let plan = VideoTranscoder.plan(info: sourceInfo, limitBytes: limit)
        #expect(plan.audioBitrate == Int(sourceRate.rounded(.up)))
        let output = dir.appending(path: "clip.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in }

        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        #expect(size <= limit)
        let audio = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == sourceASBD.mSampleRate)
        #expect(asbd.mChannelsPerFrame == sourceASBD.mChannelsPerFrame)
        // A copy keeps the source's data rate; a re-encode at the old default would land near 96 kbit/s.
        let outputRate = try await audio.load(.estimatedDataRate)
        #expect(abs(outputRate - sourceRate) <= sourceRate * 0.05)
        let outputInfo = try await VideoInfo.read(output)
        #expect(outputInfo.audioTrackCount == 1)
    }

    @Test(
        .enabled("needs H.264 and a software HEVC encoder") { ClipMaker.softwareHEVCAvailable() },
        .timeLimit(.minutes(1)))
    func softwareEncoderPathTranscodesWithoutCrashing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1, audio: true)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 160_000)
        let output = dir.appending(path: "clip.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output, hardwareEncoder: false) {
            _ in /* progress not checked here */
        }

        let info = try await VideoInfo.read(output)
        #expect(info.width == 320 && info.height == 240)
        #expect(info.audioTrackCount == 1)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func mixesSeveralAudioTracksIntoOneAACTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(
            input, width: 640, height: 480, fps: 30, seconds: 2, audio: true, audioTracks: 2)
        let sourceInfo = try await VideoInfo.read(input)
        #expect(sourceInfo.audioTrackCount == 2)
        #expect(sourceInfo.audioDataRate == nil)
        let plan = VideoTranscoder.plan(info: sourceInfo, limitBytes: 1 << 20)
        #expect(plan.audioBitrate == 160_000)
        let output = dir.appending(path: "clip.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in }

        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        let format = try #require(try await audio.first?.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == 48_000 && asbd.mChannelsPerFrame == 2)
    }

    @Test(
        .enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() }, .timeLimit(.minutes(1)))
    func cancellationThrowsCancellationErrorAndLeavesNoOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1, audio: true)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 64_000)
        let output = dir.appending(path: "clip.telegram.mp4")

        let task = Task { try await VideoTranscoder.transcode(input, plan: plan, output: output) { _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func unreadableInputThrowsCannotRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "junk.mov")
        try Data(repeating: 0xAB, count: 64).write(to: input)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 64_000)
        await #expect(throws: TranscodeError.cannotRead) {
            _ = try await VideoTranscoder.transcode(input, plan: plan, output: dir.appending(path: "o.mp4")) {
                _ in
            }
        }
    }

    @Test(
        .enabled("needs an H.264 encoder") { ClipMaker.h264Available() }, .timeLimit(.minutes(1)))
    func transcodesToMobileFriendlyH264() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "wide.mov")
        try await ClipMaker.make(input, width: 640, height: 360, fps: 30, seconds: 1, audio: true)
        let source = try await VideoInfo.read(input)
        #expect(source.codec == kCMVideoCodecType_H264)
        let plan = VideoTranscoder.plan(
            info: source, limitBytes: Self.fiftyMB, maxLongSide: 320, codec: .h264)
        #expect(plan.width == 320 && plan.height == 180)
        let output = dir.appending(path: "wide.telegram.mp4")
        let logged = AskedStrings()

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output, log: { logged.add($0) }) {
            _ in /* progress not checked here */
        }

        let info = try await VideoInfo.read(output)
        #expect(info.codec == kCMVideoCodecType_H264)
        #expect(max(info.width, info.height) <= 320)
        #expect(info.width == 320 && info.height == 180)
        #expect(abs(info.duration - source.duration) < 0.2)
        #expect(info.audioTrackCount == 1)
        #expect(try #require(logged.all.last).hasSuffix(", h264 320×180"))
    }

    @Test(
        .enabled("needs H.264 and a software H.264 encoder") { ClipMaker.softwareH264Available() },
        .timeLimit(.minutes(1)))
    func softwareH264PathTranscodesWithoutCrashing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1)
        let plan = TranscodePlan(
            width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 0, codec: .h264)
        let output = dir.appending(path: "clip.telegram.mp4")

        _ = try await VideoTranscoder.transcode(input, plan: plan, output: output, hardwareEncoder: false) {
            _ in /* progress not checked here */
        }

        let info = try await VideoInfo.read(output)
        #expect(info.codec == kCMVideoCodecType_H264)
        #expect(info.width == 320 && info.height == 240)
    }
}

/// Writes a short H.264 clip of solid frames (plus optional silent AAC audio, `audioTracks` tracks of it)
/// with AVAssetWriter.
enum ClipMaker {
    struct Failure: Error {}

    /// False on hosts without an H.264 encoder for the source clip or an HEVC encoder for the transcode
    /// (some CI VMs); the end-to-end tests are skipped there.
    static func encodersAvailable() -> Bool {
        canEncode(kCMVideoCodecType_H264) && canEncode(kCMVideoCodecType_HEVC)
    }

    /// False on hosts without an H.264 encoder for the source clip; tests that only read the clip skip there.
    static func h264Available() -> Bool {
        canEncode(kCMVideoCodecType_H264)
    }

    /// False on hosts without an H.264 encoder for the source clip or a software HEVC encoder.
    static func softwareHEVCAvailable() -> Bool {
        let software =
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
            as CFDictionary
        return canEncode(kCMVideoCodecType_H264) && canEncode(kCMVideoCodecType_HEVC, specification: software)
    }

    /// False on hosts without a software H.264 encoder (the source clip is H.264 too).
    static func softwareH264Available() -> Bool {
        let software =
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
            as CFDictionary
        return canEncode(kCMVideoCodecType_H264) && canEncode(kCMVideoCodecType_H264, specification: software)
    }

    private static func canEncode(_ codec: CMVideoCodecType, specification: CFDictionary? = nil) -> Bool {
        _ = CrashBacktrace.installed
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: codec, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        VTCompressionSessionInvalidate(session)
        return true
    }

    static func make(
        _ url: URL, width: Int, height: Int, fps: Int32, seconds: Int, audio: Bool = false,
        audioTracks: Int = 1
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw Failure() }
        writer.add(input)
        let sounds = audio ? try (0..<audioTracks).map { _ in try SilentAudio(fps: Int(fps)) } : []
        for sound in sounds {
            guard writer.canAdd(sound.input) else { throw Failure() }
            writer.add(sound.input)
        }
        guard writer.startWriting() else { throw Failure() }
        writer.startSession(atSourceTime: .zero)
        // Each input is fed on its own queue as the writer asks for data, so the writer's interleaving cannot
        // deadlock them against each other (lock-step feeding hung on 2 s clips with audio).
        let count = Int(fps) * seconds
        var feeders = [
            Feeder(input: input, count: count, label: "video") { frame in
                guard let pool = adaptor.pixelBufferPool else { return false }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { return false }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    memset(base, Int32(frame * 8 % 255), CVPixelBufferGetDataSize(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                return adaptor.append(
                    buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            }
        ]
        for (index, sound) in sounds.enumerated() {
            feeders.append(
                Feeder(input: sound.input, count: count, label: "audio\(index)") { frame in
                    guard let chunk = try? sound.chunk(index: frame) else { return false }
                    return sound.input.append(chunk)
                })
        }
        let all = feeders
        let results = await withTaskGroup(of: Bool.self) { group in
            for feeder in all { group.addTask { await feeder.run() } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        guard results.allSatisfy({ $0 }) else {
            writer.cancelWriting()
            throw Failure()
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(fps) * Int64(seconds), timescale: fps))
        await writer.finishWritingOnce()
        guard writer.status == .completed else { throw Failure() }
    }
}

/// Appends `count` samples to one writer input on its own queue whenever the input is ready, then marks it
/// finished. `append` returns false on failure, which ends the feed.
private final class Feeder: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let count: Int
    private let queue: DispatchQueue
    private let append: (Int) -> Bool
    /// Touched only on `queue`.
    private var index = 0
    private var done = false

    init(input: AVAssetWriterInput, count: Int, label: String, append: @escaping (Int) -> Bool) {
        self.input = input
        self.count = count
        self.queue = DispatchQueue(label: "ClipMaker.\(label)")
        self.append = append
    }

    /// True once every sample was appended.
    func run() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !done && input.isReadyForMoreMediaData {
                    let finished = index >= count
                    let ok = finished || append(index)
                    if finished || !ok {
                        done = true
                        input.markAsFinished()
                        continuation.resume(returning: ok)
                        return
                    }
                    index += 1
                }
            }
        }
    }
}

/// 48 kHz stereo 16-bit silence, one chunk per video frame.
private struct SilentAudio {
    static let rate = 48_000
    let input: AVAssetWriterInput
    let format: CMAudioFormatDescription
    let frames: Int

    init(fps: Int) throws {
        frames = Self.rate / fps
        input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64_000,
            ])
        input.expectsMediaDataInRealTime = false
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(Self.rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw ClipMaker.Failure() }
        self.format = format
    }

    func chunk(index: Int) throws -> CMSampleBuffer {
        let length = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard let block else { throw ClipMaker.Failure() }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: Int64(index * frames), timescale: Int32(Self.rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw ClipMaker.Failure() }
        return sample
    }
}
