import AVFoundation
import Foundation
import ImageIO
import QuickTubeCore
import Testing

@Suite struct GIFUploaderTests {
    // MARK: - Frame plan

    @Test func oneFramePerTickForTheWholeClip() {
        let times = GIFUploader.frameTimes(duration: 2, fps: 10, maxSeconds: 30)
        #expect(times.count == 20)
        #expect(times.first == .zero)
        #expect(abs((times.last?.seconds ?? 0) - 1.9) < 0.0001)
    }

    @Test func framesAreSpacedByOneOverFPS() {
        let times = GIFUploader.frameTimes(duration: 1, fps: 4, maxSeconds: 30)
        #expect(times.map(\.seconds) == [0, 0.25, 0.5, 0.75])
    }

    @Test func capsAtMaxSecondsFromTheStart() {
        let times = GIFUploader.frameTimes(duration: 120, fps: 10, maxSeconds: 30)
        #expect(times.count == 300)
        #expect((times.last?.seconds ?? 0) < 30)
    }

    @Test func partialTickAtTheEndStillGetsAFrame() {
        let times = GIFUploader.frameTimes(duration: 1.05, fps: 10, maxSeconds: 30)
        #expect(times.count == 11)
        #expect((times.last?.seconds ?? 0) < 1.05)
    }

    @Test func emptyOrInvalidDurationPlansNothing() {
        #expect(GIFUploader.frameTimes(duration: 0, fps: 10, maxSeconds: 30).isEmpty)
        #expect(GIFUploader.frameTimes(duration: .nan, fps: 10, maxSeconds: 30).isEmpty)
        #expect(GIFUploader.frameTimes(duration: -1, fps: 10, maxSeconds: 30).isEmpty)
    }

    @Test func nonPositiveFPSIsTreatedAsOne() {
        #expect(GIFUploader.frameTimes(duration: 3, fps: 0, maxSeconds: 30).count == 3)
    }

    // MARK: - Output size

    @Test func scalesDownToMaxWidthKeepingAspect() {
        let size = GIFUploader.outputSize(for: CGSize(width: 1920, height: 1080), maxWidth: 800)
        #expect(size == CGSize(width: 800, height: 450))
    }

    @Test func neverUpscales() {
        let size = GIFUploader.outputSize(for: CGSize(width: 640, height: 480), maxWidth: 800)
        #expect(size == CGSize(width: 640, height: 480))
    }

    @Test func portraitIsLimitedByWidthToo() {
        let size = GIFUploader.outputSize(for: CGSize(width: 1080, height: 1920), maxWidth: 540)
        #expect(size == CGSize(width: 540, height: 960))
    }

    @Test func oddResultsAreWholePixelsAndKeepAspect() {
        let size = GIFUploader.outputSize(for: CGSize(width: 1001, height: 333), maxWidth: 500)
        #expect(size.width == 500)
        #expect(size.height == size.height.rounded())
        #expect(abs(size.height - 333.0 * 500 / 1001) <= 0.5)
    }

    @Test func tinyHeightsStayAtLeastOnePixel() {
        let size = GIFUploader.outputSize(for: CGSize(width: 4000, height: 2), maxWidth: 320)
        #expect(size.width == 320)
        #expect(size.height >= 1)
    }

    @Test func outputSitsNextToTheRecording() {
        let file = URL(filePath: "/tmp/rec/2026-10-10 10.00.00.mp4")
        #expect(GIFUploader.outputURL(for: file).path == "/tmp/rec/2026-10-10 10.00.00.gif")
    }

    // MARK: - End to end

    @Test(.enabled("needs an H.264 encoder") { ClipMaker.h264Available() })
    func rendersAGeneratedClipToALoopingGIF() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "clip.mov")
        do {
            try await ClipMaker.make(input, width: 640, height: 480, fps: 30, seconds: 1)
        } catch {
            // The clip writer is unavailable on this host; nothing to convert.
            return
        }
        let options = GIFOptions(fps: 10, maxWidth: 320, maxSeconds: 30)
        let uploader = GIFUploader(options: { options })
        let seen = ProgressLog()
        let stages = StageList()
        let result = try await uploader.upload(
            file: input, title: "clip", context: UploadContext(onStatus: { stages.add($0) })
        ) { seen.add($0) }

        let output = dir.appending(path: "clip.gif")
        #expect(result.link == output)
        #expect(result.link.isFileURL)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let plan = GIFUploader.frameTimes(duration: 1, fps: 10, maxSeconds: 30)
        #expect(CGImageSourceGetCount(source) == plan.count)
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(frame?[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(frame?[kCGImagePropertyPixelHeight] as? Int == 240)
        let frameGIF = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (frameGIF?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        #expect(abs(delay - 0.1) < 0.011)
        #expect(stages.values == ["Rendering GIF"])
        let values = seen.values
        #expect(values == values.sorted())
        #expect(values.last == 1)
    }

    @Test func unreadableInputThrowsCannotRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "garbage.mp4")
        try Data("not a movie".utf8).write(to: input)
        let uploader = GIFUploader(options: { GIFOptions(fps: 10, maxWidth: 320, maxSeconds: 5) })
        await #expect(throws: GIFError.cannotRead) {
            _ = try await uploader.upload(file: input, title: "x") { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "garbage.gif").path))
    }
}

final class StageList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ value: String) { lock.withLock { list.append(value) } }
    var values: [String] { lock.withLock { list } }
}
