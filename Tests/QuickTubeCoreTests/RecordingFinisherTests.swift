import AVFoundation
import Foundation
import QuickTubeCore
import Testing

@Suite struct RecordingFinisherTests {
    typealias Piece = (segment: Int, range: ClosedRange<TimeInterval>)

    /// Pieces as comparable tuples, rounded to the millisecond.
    private func flat(_ plan: [Piece]) -> [[Double]] {
        plan.map {
            [
                Double($0.segment), ($0.range.lowerBound * 1000).rounded() / 1000,
                ($0.range.upperBound * 1000).rounded() / 1000,
            ]
        }
    }

    @Test func noTrimKeepsEverySegmentWhole() {
        let plan = RecordingFinisher.plan(durations: [3, 2], trim: TrimSettings(head: 0, tail: 0))
        #expect(flat(plan) == [[0, 0, 3], [1, 0, 2]])
    }

    @Test func headAndTailTrimInsideOneSegment() {
        let plan = RecordingFinisher.plan(durations: [10], trim: TrimSettings(head: 0.5, tail: 1))
        #expect(flat(plan) == [[0, 0.5, 9]])
    }

    @Test func tailTrimSpansSegmentsFromTheEnd() {
        // The last segment (0.4 s) is dropped entirely; 0.6 s more comes off the one before.
        let plan = RecordingFinisher.plan(durations: [3, 2, 0.4], trim: TrimSettings(head: 0, tail: 1))
        #expect(flat(plan) == [[0, 0, 3], [1, 0, 1.4]])
    }

    @Test func headTrimSpansSegmentsFromTheStart() {
        let plan = RecordingFinisher.plan(durations: [1, 3], trim: TrimSettings(head: 1.5, tail: 0))
        #expect(flat(plan) == [[1, 0.5, 3]])
    }

    @Test func trimNeverLeavesLessThanHalfASecond() {
        // 2 s total, 3 + 3 s asked: the tail takes all it can (1.5 s), the head nothing.
        let plan = RecordingFinisher.plan(durations: [1, 1], trim: TrimSettings(head: 3, tail: 3))
        #expect(flat(plan) == [[0, 0, 0.5]])
        let total = plan.reduce(0) { $0 + $1.range.upperBound - $1.range.lowerBound }
        #expect(abs(total - RecordingFinisher.minimumDuration) < 1e-9)
    }

    @Test func headGetsWhatTheTailLeaves() {
        let plan = RecordingFinisher.plan(durations: [3], trim: TrimSettings(head: 2, tail: 1))
        #expect(flat(plan) == [[0, 1.5, 2]])
    }

    @Test func shortRecordingsAreNotTrimmed() {
        let plan = RecordingFinisher.plan(durations: [0.3], trim: TrimSettings(head: 1, tail: 1))
        #expect(flat(plan) == [[0, 0, 0.3]])
    }

    @Test func emptyAndNegativeInputsAreSafe() {
        #expect(RecordingFinisher.plan(durations: [], trim: TrimSettings(head: 1, tail: 1)).isEmpty)
        let plan = RecordingFinisher.plan(durations: [0, 2, -1], trim: TrimSettings(head: -1, tail: -1))
        #expect(flat(plan) == [[1, 0, 2]])
    }

    @Test func singleSegmentWithoutTrimIsMovedAsIs() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = dir.appending(path: "a.seg1.mp4")
        try Data([1, 2, 3]).write(to: segment)
        let output = dir.appending(path: "Title.mp4")

        let result = try await RecordingFinisher().finish(segments: [segment], trim: .none, output: output)

        #expect(result == output)
        #expect(try Data(contentsOf: output) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: segment.path))
    }

    @Test func existingOutputIsNeverOverwritten() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = dir.appending(path: "a.seg1.mp4")
        try Data([1]).write(to: segment)
        let output = dir.appending(path: "Title.mp4")
        try Data([9]).write(to: output)

        await #expect(throws: RecorderError.finishFailed("Title.mp4 already exists.")) {
            _ = try await RecordingFinisher().finish(segments: [segment], trim: .none, output: output)
        }
        #expect(try Data(contentsOf: output) == Data([9]))
        #expect(FileManager.default.fileExists(atPath: segment.path))
    }

    @Test func noSegmentsFails() async {
        await #expect(throws: RecorderError.self) {
            _ = try await RecordingFinisher().finish(
                segments: [], trim: .none, output: URL(fileURLWithPath: "/tmp/never.mp4"))
        }
    }

    @Test func unreadableSegmentsFailAndAreKept() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appending(path: "a.seg1.mp4")
        let second = dir.appending(path: "a.seg2.mp4")
        try Data(repeating: 0xAB, count: 64).write(to: first)
        try Data(repeating: 0xCD, count: 64).write(to: second)
        let output = dir.appending(path: "Title.mp4")

        await #expect {
            _ = try await RecordingFinisher().finish(
                segments: [first, second], trim: TrimSettings(head: 0, tail: 1), output: output)
        } throws: { error in
            if case RecorderError.finishFailed = error { return true }
            return false
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled("needs H.264 and HEVC encoders") { ClipMaker.encodersAvailable() })
    func concatenatesAndTrimsTwoClips() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appending(path: "a.seg1.mov")
        let second = dir.appending(path: "a.seg2.mov")
        try await ClipMaker.make(first, width: 320, height: 240, fps: 30, seconds: 1, audio: true)
        try await ClipMaker.make(second, width: 320, height: 240, fps: 30, seconds: 1, audio: true)
        let output = dir.appending(path: "Title.mp4")

        let result = try await RecordingFinisher().finish(
            segments: [first, second], trim: TrimSettings(head: 0.25, tail: 0.5), output: output)

        #expect(result == output)
        let info = try await VideoInfo.read(output)
        #expect(info.width == 320 && info.height == 240)
        #expect(abs(info.duration - 1.25) < 0.15)
        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.contains { $0.mediaType == .audio })
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
