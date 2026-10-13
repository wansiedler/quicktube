import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
import VideoToolbox

@testable import QuickTubeCore

@Suite struct RecordingEncodingTests {
    @Test func realTimeHardwarePropertiesAddKeyFramesRealTimeAndALooserCap() throws {
        let properties = VideoEncoding.compressionProperties(
            bitrate: 8_000_000, fps: 60, hardware: true, realTime: true)
        #expect(properties[AVVideoAverageBitRateKey] as? Int == 8_000_000)
        #expect(properties[AVVideoExpectedSourceFrameRateKey] as? Int == 60)
        #expect(properties[AVVideoMaxKeyFrameIntervalDurationKey] as? Int == 2)
        #expect(properties[AVVideoAllowFrameReorderingKey] as? Bool == false)
        #expect(properties[kVTCompressionPropertyKey_RealTime as String] as? Bool == true)
        #expect(
            properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] as? Bool
                == true)
        let limits = try #require(
            properties[kVTCompressionPropertyKey_DataRateLimits as String] as? [NSNumber])
        #expect(limits == [NSNumber(value: 2_000_000), NSNumber(value: 1.0)])
    }

    @Test func realTimeSoftwarePropertiesSkipTheVideoToolboxKeys() {
        let properties = VideoEncoding.compressionProperties(
            bitrate: 8_000_000, fps: 30, hardware: false, realTime: true)
        #expect(properties[AVVideoMaxKeyFrameIntervalDurationKey] as? Int == 2)
        #expect(properties[kVTCompressionPropertyKey_RealTime as String] == nil)
        #expect(properties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect(properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] == nil)
    }

    @Test func transcodePropertiesHaveNoRealTimeKeys() {
        let properties = VideoEncoding.compressionProperties(bitrate: 8_000_000, fps: 30, hardware: true)
        #expect(properties[AVVideoMaxKeyFrameIntervalDurationKey] == nil)
        #expect(properties[kVTCompressionPropertyKey_RealTime as String] == nil)
    }

    @Test func conformerPassesTheFirstFormatThroughAndConvertsALaterOne() throws {
        let conformer = AudioConformer()
        let mono = try Feed.audioSample(pts: .zero, frames: 1_600, channels: 1)
        #expect(conformer.conform(mono) === mono)
        let monoAgain = try Feed.audioSample(
            pts: CMTime(value: 1_600, timescale: 48_000), frames: 1_600, channels: 1)
        #expect(conformer.conform(monoAgain) === monoAgain)
        let stereoPTS = CMTime(value: 3_200, timescale: 48_000)
        let stereo = try Feed.audioSample(pts: stereoPTS, frames: 1_600, channels: 2)
        let converted = try #require(conformer.conform(stereo))
        #expect(converted !== stereo)
        let description = try #require(CMSampleBufferGetFormatDescription(converted))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(CMSampleBufferGetNumSamples(converted) == 1_600)
        #expect(CMSampleBufferGetPresentationTimeStamp(converted) == stereoPTS)
        #expect(conformer.converted == 1)
    }

    @Test func summaryLineNamesFramesDropsDurationSizeAndTarget() {
        let stats = RecordingWriter.Stats(frames: 1800, droppedFrames: 3, droppedAudio: 5, seconds: 30.04)
        let line = RecordingWriter.summaryLine(
            segment: 2, stats: stats, bytes: 52_428_800, bitrate: 14_657_864)
        #expect(
            line
                == "Recorder: segment 2 — 1800 frames, 3 frames dropped, 5 audio buffers dropped, 30.0 s, "
                + "52.4 MB, target 14.7 Mbit/s")
    }
}

@Suite struct DeadlineTests {
    struct Late: Error {}
    struct Boom: Error {}

    @Test(.timeLimit(.minutes(1))) func returnsWhenTheOperationFinishesInTime() async throws {
        try await Deadline.run(timeout: .seconds(5), error: Late()) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(.timeLimit(.minutes(1))) func throwsTheTimeoutErrorWhenTheOperationHangs() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: Late.self) {
            try await Deadline.run(timeout: .milliseconds(50), error: Late()) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1))) func passesTheOperationsErrorThrough() async {
        await #expect(throws: Boom.self) {
            try await Deadline.run(timeout: .seconds(5), error: Late()) { throw Boom() }
        }
    }
}

@Suite struct RecordingWriterTests {
    static let width = 640
    static let height = 360

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString).mp4")
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func writesVideoAndTwoAudioTracks() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: true, microphone: true)
        try await Feed.run(writer, frames: 30, system: 2, microphone: 1)
        let result = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        #expect(result == url)

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.count == 2)
        let size = try await video[0].load(.naturalSize)
        #expect(size == CGSize(width: Self.width, height: Self.height))
        let formats = try await video[0].load(.formatDescriptions)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)
        for track in audio {
            let audioFormats = try await track.load(.formatDescriptions)
            #expect(audioFormats.first.map(CMFormatDescriptionGetMediaSubType) == kAudioFormatMPEG4AAC)
        }
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 30)
        #expect(writer.stats.frames == 30)
        #expect(writer.stats.droppedAudio == 0)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func aMicrophoneSwitchingFromMonoToStereoKeepsTheSegment() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: true)
        try await Feed.run(writer, frames: 30, microphone: 1, microphoneSwitch: (frame: 15, channels: 2))
        _ = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        let audioDuration = try await audio.first?.load(.timeRange).duration.seconds ?? 0
        #expect(audioDuration > 0.9)
        #expect(writer.stats.droppedAudio == 0)
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 30)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func videoIsTaggedBT709() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        try await Feed.run(writer, frames: 10)
        _ = try await writer.finish(at: CMTime(value: 1, timescale: 3))
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        func tag(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
        }
        #expect(
            tag(kCMFormatDescriptionExtension_ColorPrimaries)
                == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(
            tag(kCMFormatDescriptionExtension_TransferFunction)
                == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(
            tag(kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
                as String)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func audioOffWritesOnlyVideo() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        // Audio handed to a writer without audio inputs is ignored.
        try await Feed.run(writer, frames: 30, system: 2, microphone: 1)
        _ = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func incompleteFramesAreSkipped() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        try await Feed.run(writer, frames: 30, incomplete: [0, 10, 11])
        _ = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 27)
        #expect(writer.stats.frames == 27)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func aStaticTailIsKeptUntilTheStopTime() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        try await Feed.run(writer, frames: 30)
        _ = try await writer.finish(at: CMTime(value: 3, timescale: 1))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(duration > 2.9 && duration < 3.2)
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 31)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func noTailWhenTheLastFrameIsRecent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        try await Feed.run(writer, frames: 30)
        _ = try await writer.finish(at: CMTime(value: 1_200, timescale: 1_000))
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 30)
    }

    @Test(
        .enabled("needs the software HEVC encoder") { ClipMaker.softwareHEVCEncoderAvailable() },
        .timeLimit(.minutes(1)))
    func softwareEncoderWrites() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: true, microphone: true, hardware: false)
        try await Feed.run(writer, frames: 30, system: 2, microphone: 2)
        _ = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 2)
        try #require(writer.stats.droppedFrames == 0)
        #expect(try await Feed.frameCount(url) == 30)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func aHigherBitrateMakesALargerFile() async throws {
        func size(_ bitrate: Int) async throws -> Int {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try RecordingWriter(
                url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: bitrate,
                systemAudio: false, microphone: false)
            try await Feed.run(writer, frames: 60, noise: true)
            _ = try await writer.finish(at: CMTime(value: 2, timescale: 1))
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize ?? 0
        }
        let low = try await size(2_000_000)
        let high = try await size(8_000_000)
        #expect(low > 0)
        #expect(high > low)
    }

    @Test(.enabled("needs an HEVC encoder") { ClipMaker.hevcAvailable() }, .timeLimit(.minutes(1)))
    func finishingWithoutFramesThrowsAndLeavesNoFile() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(
            url: url, width: Self.width, height: Self.height, fps: 30, videoBitrate: 2_000_000,
            systemAudio: false, microphone: false)
        await #expect(throws: RecorderError.self) {
            _ = try await writer.finish(at: CMTime(value: 1, timescale: 1))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// Synthetic ScreenCaptureKit-like input: 420v frames tagged with an `SCStreamFrameInfo.status` and 48 kHz
/// Float32 sine audio, appended in PTS order; each append waits until the writer is ready, so no sample is
/// dropped however loaded the machine is.
enum Feed {
    struct Failure: Error {}
    static let sampleRate = 48_000

    static func run(
        _ writer: RecordingWriter, frames: Int, system: Int? = nil, microphone: Int? = nil,
        microphoneSwitch: (frame: Int, channels: Int)? = nil, incomplete: Set<Int> = [], noise: Bool = false
    ) async throws {
        let fps = 30
        let chunk = sampleRate / fps
        for index in 0..<frames {
            let pts = CMTime(value: Int64(index), timescale: Int32(fps))
            try await waitUntilReady { writer.isReady(for: .screen) }
            writer.append(
                screen: try videoSample(
                    pts: pts, status: incomplete.contains(index) ? .idle : .complete, noise: noise,
                    seed: index))
            let audioPTS = CMTime(value: Int64(index * chunk), timescale: Int32(sampleRate))
            if let system {
                try await waitUntilReady { writer.isReady(for: .system) }
                writer.append(
                    audio: try audioSample(pts: audioPTS, frames: chunk, channels: system), kind: .system)
            }
            if var microphone {
                if let microphoneSwitch, index >= microphoneSwitch.frame {
                    microphone = microphoneSwitch.channels
                }
                try await waitUntilReady { writer.isReady(for: .microphone) }
                writer.append(
                    audio: try audioSample(pts: audioPTS, frames: chunk, channels: microphone),
                    kind: .microphone)
            }
        }
    }

    /// Unbounded on purpose: a loaded machine only makes this slower; `.timeLimit` guards a real hang.
    private static func waitUntilReady(_ ready: () -> Bool) async throws {
        while !ready() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func videoSample(pts: CMTime, status: SCFrameStatus, noise: Bool, seed: Int) throws
        -> CMSampleBuffer
    {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(
            nil, RecordingWriterTests.width, RecordingWriterTests.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { throw Failure() }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        // xorshift: cheap noise the encoder cannot predict.
        var state = UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let length =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            if noise {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for offset in 0..<length {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    bytes[offset] = 16 + UInt8(truncatingIfNeeded: state) % 220
                }
            } else {
                memset(base, Int32(plane == 0 ? 16 + seed * 7 % 200 : 128), length)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { throw Failure() }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard let sample,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        else { throw Failure() }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary, Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
            Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque())
        return sample
    }

    /// Float32 non-interleaved sine (what ScreenCaptureKit delivers), built through `AVAudioPCMBuffer`.
    static func audioSample(pts: CMTime, frames: Int, channels: Int) throws -> CMSampleBuffer {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)),
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw Failure() }
        pcm.frameLength = AVAudioFrameCount(frames)
        let start = Int(pts.value)
        for channel in 0..<channels {
            guard let data = pcm.floatChannelData?[channel] else { throw Failure() }
            for frame in 0..<frames {
                data[frame] = Float(
                    0.2 * sin(2 * Double.pi * 440 * Double(start + frame) / Double(sampleRate)))
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)), presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        guard let sample else { throw Failure() }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pcm.audioBufferList)
        guard status == noErr else { throw Failure() }
        return sample
    }

    /// Video samples in the file, counted with `AVAssetReader`.
    static func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw Failure() }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }
}
