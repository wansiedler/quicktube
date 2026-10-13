import AVFoundation
import Foundation

/// Seconds cut off the start and the end of a finished recording.
public struct TrimSettings: Sendable, Equatable {
    public var head: TimeInterval
    public var tail: TimeInterval

    public init(head: TimeInterval, tail: TimeInterval) {
        self.head = head
        self.tail = tail
    }

    public static let none = TrimSettings(head: 0, tail: 0)

    public var isZero: Bool { head <= 0 && tail <= 0 }
}

/// Turns the segment files of one recording into the final file.
public protocol RecordingFinishing: Sendable {
    /// Writes `output` from `segments` with `trim` applied, deletes the segments and returns `output`.
    /// On failure the segments are kept and `RecorderError.finishFailed` is thrown.
    func finish(segments: [URL], trim: TrimSettings, output: URL) async throws -> URL
}

/// Concatenates segments with `AVMutableComposition` and exports them without re-encoding.
public actor RecordingFinisher: RecordingFinishing {
    /// Trimming never leaves less than this much of a recording.
    public static let minimumDuration: TimeInterval = 0.5

    public init() {}

    /// Pure: which part of which segment survives the trim. The kept span is `[head, total − tail]` on the
    /// joined timeline, so the tail can swallow whole trailing segments and the head whole leading ones.
    /// Trims are clamped so at least `minimumDuration` remains; the tail (the stop-hotkey press) is served
    /// first. Recordings shorter than `minimumDuration` are not trimmed. Empty segments are dropped.
    public static func plan(
        durations: [TimeInterval], trim: TrimSettings
    ) -> [(segment: Int, range: ClosedRange<TimeInterval>)] {
        let lengths = durations.map { max(0, $0) }
        let total = lengths.reduce(0, +)
        var head = max(0, trim.head)
        var tail = max(0, trim.tail)
        if total <= minimumDuration {
            head = 0
            tail = 0
        } else {
            let budget = total - minimumDuration
            tail = min(tail, budget)
            head = min(head, budget - tail)
        }
        let keepStart = head
        let keepEnd = total - tail

        var pieces: [(segment: Int, range: ClosedRange<TimeInterval>)] = []
        var start: TimeInterval = 0
        for (index, length) in lengths.enumerated() {
            let end = start + length
            let low = max(start, keepStart)
            let high = min(end, keepEnd)
            if high - low > 1e-9 {
                pieces.append((index, (low - start)...(high - start)))
            }
            start = end
        }
        return pieces
    }

    public func finish(segments: [URL], trim: TrimSettings, output: URL) async throws -> URL {
        guard !segments.isEmpty else { throw RecorderError.finishFailed("No segments were recorded.") }
        // Never overwrite (or, after a failed export, delete) a file that is already there.
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw RecorderError.finishFailed("\(output.lastPathComponent) already exists.")
        }
        if segments.count == 1, trim.isZero {
            do {
                try FileManager.default.moveItem(at: segments[0], to: output)
            } catch {
                throw RecorderError.finishFailed(error.localizedDescription)
            }
            return output
        }
        do {
            try await Self.export(segments: segments, trim: trim, output: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            if case RecorderError.finishFailed = error { throw error }
            throw RecorderError.finishFailed(error.localizedDescription)
        }
        for segment in segments {
            try? FileManager.default.removeItem(at: segment)
        }
        return output
    }

    /// Composition and export session are not Sendable; they never leave this function.
    private nonisolated static func export(segments: [URL], trim: TrimSettings, output: URL) async throws {
        let assets = segments.map { AVURLAsset(url: $0) }
        var durations: [CMTime] = []
        for asset in assets {
            durations.append(try await asset.load(.duration))
        }
        let pieces = plan(durations: durations.map(\.seconds), trim: trim)
        guard !pieces.isEmpty else { throw RecorderError.finishFailed("The recording is empty.") }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for piece in pieces {
            let timescale = max(durations[piece.segment].timescale, 600)
            let start = CMTime(seconds: piece.range.lowerBound, preferredTimescale: timescale)
            let end = CMTime(seconds: piece.range.upperBound, preferredTimescale: timescale)
            let range = CMTimeRange(start: start, end: end)
            try await composition.insertTimeRange(range, of: assets[piece.segment], at: cursor)
            cursor = cursor + range.duration
        }

        guard
            let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw RecorderError.finishFailed("Passthrough export is not available.") }
        try await session.export(to: output, as: .mp4)
    }
}
