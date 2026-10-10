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
        #expect(plan.audioBitrate == 96_000)
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

    // MARK: - End to end

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
    func transcodesAGeneratedClip() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1)
        let plan = TranscodePlan(width: 320, height: 240, videoBitrate: 300_000, audioBitrate: 64_000)
        let output = dir.appending(path: "clip.telegram.mp4")
        let seen = ProgressLog()
        let result = try await VideoTranscoder.transcode(input, plan: plan, output: output) { seen.add($0) }

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

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
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

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
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

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
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

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
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
}

/// Writes a short H.264 clip of solid frames (plus optional silent LPCM audio) with AVAssetWriter.
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

    private static func canEncode(_ codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        VTCompressionSessionInvalidate(session)
        return true
    }

    static func make(
        _ url: URL, width: Int, height: Int, fps: Int32, seconds: Int, audio: Bool = false
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
        let sound = audio ? try SilentAudio(fps: Int(fps)) : nil
        if let sound {
            guard writer.canAdd(sound.input) else { throw Failure() }
            writer.add(sound.input)
        }
        guard writer.startWriting() else { throw Failure() }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(Int(fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure() }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure() }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 8 % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
            else {
                throw Failure()
            }
            if let sound {
                while !sound.input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard sound.input.append(try sound.chunk(index: frame)) else { throw Failure() }
            }
        }
        input.markAsFinished()
        sound?.input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(fps) * Int64(seconds), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure() }
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
