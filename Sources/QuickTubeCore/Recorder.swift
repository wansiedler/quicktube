import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What a recording is made with; read once per recording, so every segment of it matches.
public struct RecorderOptions: Sendable, Equatable {
    public var quality: RecordingQuality
    /// Other apps' audio (`SCStreamConfiguration.capturesAudio`); QuickTube's own sound is excluded.
    public var systemAudio: Bool
    public var microphone: Bool

    public init(quality: RecordingQuality = .default, systemAudio: Bool = false, microphone: Bool = true) {
        self.quality = quality
        self.systemAudio = systemAudio
        self.microphone = microphone
    }
}

/// Records a display, a window or a display region, with optional system and microphone audio,
/// to HEVC .mp4 segments: `<date>.seg1.mp4`, `.seg2.mp4`, … ScreenCaptureKit delivers the sample buffers;
/// `RecordingWriter` encodes them at the bitrate of the recording's `RecordingQuality.Bitrate` preset.
/// Pausing closes the current segment, resuming opens the next one with the same target and options.
/// The microphone follows the system default input: see `microphoneChanged(uid:name:)`.
public actor Recorder: ScreenRecorder {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Movies/QuickTube")

    private struct Session {
        let stream: SCStream
        let writer: RecordingWriter
        let fileURL: URL
        let output: StreamOutput
        let index: Int
        let bitrate: Int
        /// The input device the microphone was opened on; nil when unknown or not recorded.
        let microphoneUID: String?
        let microphoneName: String?
    }

    private enum State {
        case idle
        case starting
        case recording(Session)
        case pausing
        case paused
        case resuming
        /// Closing a segment and opening the next one for a microphone switch; outside callers see
        /// recording, since `pause()` and `stop()` wait for it.
        case rolling
        /// A microphone switch closed the segment but could not open the next one. Outside callers still
        /// see recording: `pause()` takes effect without a segment to close, `stop()` returns the segments.
        case interrupted
        case stopping
    }

    /// The recording in progress: where it captures, with what, its file stem, and the closed segments.
    private struct Take: Sendable {
        let target: CaptureTarget
        let options: RecorderOptions
        let stem: String
        var segments: [URL] = []
    }

    private static let stopTimeout: Duration = .seconds(10)
    /// Part of `stopTimeout`: past it the file is closed without waiting for the stream any longer.
    private static let stopCaptureTimeout: Duration = .seconds(3)

    private let directory: URL
    private let options: @Sendable () -> RecorderOptions
    private let excludedWindows: @Sendable @MainActor () -> [CGWindowID]
    private let log: @Sendable (String) -> Void
    private var state = State.idle
    private var take: Take?
    private var follower = MicrophoneFollower()
    /// The segment roll for a microphone switch in progress, and its closing half.
    private var roll: Task<RollOutcome, Never>?
    private var closing: Task<Void, Never>?
    /// Bumped by `pause()` and `stop()`: a roll begun before stops at its next step.
    private var epoch = 0
    /// Segments a roll could not close in time; `stop()` reports them as `stopTimedOut`.
    private var unfinished: [URL] = []

    /// `options` is read at the start of every recording, so Settings changes apply to the next one.
    /// `excludedWindows` lists the app's windows to keep out of display and region recordings (the HUD,
    /// the selection overlay); it is read for every segment. Any other window, the camera bubble
    /// included, is recorded.
    public init(
        directory: URL = Recorder.defaultDirectory,
        options: @escaping @Sendable () -> RecorderOptions = { RecorderOptions() },
        excludedWindows: @escaping @Sendable @MainActor () -> [CGWindowID] = { [] },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.options = options
        self.excludedWindows = excludedWindows
        self.log = log
    }

    /// Splits the `requested` exclusions into those ScreenCaptureKit lists (`available`) and those it
    /// does not, which would end up in the recording. Order follows `requested`; duplicates are dropped.
    public static func excludedWindowIDs(
        requested: [CGWindowID], available: [CGWindowID]
    ) -> (matched: [CGWindowID], missing: [CGWindowID]) {
        let known = Set(available)
        var seen: Set<CGWindowID> = []
        var matched: [CGWindowID] = []
        var missing: [CGWindowID] = []
        for id in requested where seen.insert(id).inserted {
            if known.contains(id) { matched.append(id) } else { missing.append(id) }
        }
        return (matched, missing)
    }

    public func start(target: CaptureTarget) async throws {
        guard case .idle = state else { throw RecorderError.alreadyRecording }
        state = .starting
        await waitForRoll()
        let take = Take(target: target, options: options(), stem: RecordingNaming.title(for: Date()))
        do {
            let session = try await beginSession(take, index: 1)
            state = .recording(session)
            self.take = take
            follower.began(uid: session.microphoneUID)
            followIfDefaultMoved(since: session)
        } catch {
            state = .idle
            throw error
        }
    }

    /// Closes the current segment. If closing fails the recorder is still paused (the stream is gone),
    /// keeping the segment file if one was written, and the error is rethrown. During or after a microphone
    /// switch that has no segment open there is nothing to close, and pausing just takes effect.
    public func pause() async throws {
        await takeOverFromRoll()
        switch state {
        case .rolling, .interrupted:
            state = .paused
            follower.paused()
            return
        case .recording(let session):
            state = .pausing
            follower.paused()
            defer { state = .paused }
            do {
                try await end(session)
                take?.segments.append(session.fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: session.fileURL.path) {
                    take?.segments.append(session.fileURL)
                }
                throw error
            }
        default:
            throw RecorderError.notRecording
        }
    }

    public func resume() async throws {
        guard case .paused = state, take != nil else { throw RecorderError.notPaused }
        state = .resuming
        // A roll still opening its segment would take the same file name; it is discarded when done.
        await waitForRoll()
        guard let take else { throw RecorderError.notPaused }
        do {
            let session = try await beginSession(take, index: take.segments.count + 1)
            state = .recording(session)
            follower.began(uid: session.microphoneUID)
            followIfDefaultMoved(since: session)
        } catch {
            state = .paused
            throw error
        }
    }

    /// The system default input changed (to `uid`, `name`: what the observer saw; the device is read
    /// again here, since reports can arrive out of order). While recording with the microphone, the
    /// segment is rolled: closed, and the next one opened on the new device; the recording carries on as
    /// one, with a short gap. One roll runs at a time; changes during it coalesce, and one more roll
    /// follows only if the default input then differs from the device rolled to. While paused nothing is
    /// done: resuming opens the capture on the default input of that moment. Ignored otherwise.
    public func microphoneChanged(uid: String, name: String) async {
        guard let take, take.options.microphone else { return }
        let device = DefaultInputObserver.currentDefaultInput()
        let current = device?.uid ?? uid
        if case .paused = state, current != follower.recordingUID {
            log("Microphone changed to \(device?.name ?? name) while paused; the next segment uses it")
            return
        }
        guard follower.deviceChanged(uid: current) == .rollSegment else { return }
        let epoch = self.epoch
        while true {
            let task = Task { await self.performRoll() }
            roll = task
            let outcome = await task.value
            // A pause or stop took over; it resets the follower.
            guard epoch == self.epoch else { return }
            guard case .opened(let rolledTo) = outcome else {
                follower.rollFailed()
                return
            }
            let now = DefaultInputObserver.currentDefaultInput()?.uid
            guard follower.rollFinished(rolledTo: rolledTo, currentDefault: now) == .rollSegment else {
                return
            }
        }
    }

    /// After a start or resume: a change that came while the segment was opening.
    private func followIfDefaultMoved(since session: Session) {
        guard take?.options.microphone == true, let device = DefaultInputObserver.currentDefaultInput(),
            let uid = device.uid, uid != session.microphoneUID
        else { return }
        Task { await self.microphoneChanged(uid: uid, name: device.name ?? uid) }
    }

    /// For `pause()` and `stop()`: no further roll starts, and a running one is waited for only while it
    /// closes its segment (bounded by `stopTimeout`); one that is opening the next segment is left to
    /// finish on its own and discards it.
    private func takeOverFromRoll() async {
        epoch += 1
        if let closing { await closing.value }
    }

    /// Waits for a running roll to finish completely.
    private func waitForRoll() async {
        while let roll { _ = await roll.value }
    }

    private enum RollOutcome {
        /// The next segment captures the device with this UID (nil when unknown).
        case opened(String?)
        case notOpened
    }

    /// Closes the segment and opens the next one with the same take; outside callers still see recording.
    /// Both steps are bounded by `stopTimeout`. If the next segment cannot open, nothing is captured until
    /// the recording is paused or stopped (`.interrupted`). A pause or stop during the roll takes over:
    /// the roll then opens nothing, or discards what it opened.
    private func performRoll() async -> RollOutcome {
        defer { roll = nil }
        guard case .recording(let session) = state else { return .notOpened }
        state = .rolling
        let epoch = self.epoch
        let close = Task { await self.closeForRoll(session) }
        closing = close
        await close.value
        closing = nil
        guard epoch == self.epoch, case .rolling = state, let take else { return .notOpened }
        do {
            let next = try await openSession(take, index: take.segments.count + 1)
            guard epoch == self.epoch, case .rolling = state else {
                await discard(Unchecked(value: next))
                return .notOpened
            }
            state = .recording(next)
            log("Microphone switched to \(next.microphoneName ?? "the default input") (segment rolled)")
            return .opened(next.microphoneUID)
        } catch {
            guard epoch == self.epoch, case .rolling = state else { return .notOpened }
            state = .interrupted
            log(
                "Recorder: reopening the capture for the microphone switch failed (\(error)); "
                    + "nothing is recorded until the recording is paused or stopped")
            return .notOpened
        }
    }

    /// The closing half of a roll. A segment that did not close in time is remembered, so `stop()`
    /// reports it as `stopTimedOut` and finishing can be retried.
    private func closeForRoll(_ session: Session) async {
        do {
            try await end(session)
        } catch RecorderError.stopTimedOut {
            unfinished.append(session.fileURL)
            log("Recorder: segment \(session.index) did not close in time for the microphone switch")
        } catch {
            log("Recorder: closing segment \(session.index) for the microphone switch failed: \(error)")
        }
        if FileManager.default.fileExists(atPath: session.fileURL.path) {
            take?.segments.append(session.fileURL)
        }
    }

    /// `beginSession` bounded by `stopTimeout`. A session that opens after the deadline is closed and its
    /// file removed.
    private func openSession(_ take: Take, index: Int) async throws -> Session {
        let pending = PendingSession()
        do {
            try await Deadline.run(timeout: Self.stopTimeout, error: ReopenTimedOut()) {
                let session = try await self.beginUnchecked(take, index: index)
                if !pending.deliver(session) { await self.discard(session) }
            }
        } catch {
            if let late = pending.abandon() { await discard(late) }
            throw error
        }
        guard let session = pending.abandon() else { throw ReopenTimedOut() }
        return session.value
    }

    private func beginUnchecked(_ take: Take, index: Int) async throws -> Unchecked<Session> {
        Unchecked(value: try await beginSession(take, index: index))
    }

    private func discard(_ session: Unchecked<Session>) async {
        try? await end(session.value)
        try? FileManager.default.removeItem(at: session.value.fileURL)
    }

    /// Hands a session opened under a deadline back, unless the deadline passed first.
    private final class PendingSession: @unchecked Sendable {
        private let lock = NSLock()
        private var session: Unchecked<Session>?
        private var abandoned = false

        /// False when the deadline passed: the caller discards the session.
        func deliver(_ session: Unchecked<Session>) -> Bool {
            lock.withLock {
                guard !abandoned else { return false }
                self.session = session
                return true
            }
        }

        /// Takes the delivered session, if any; later deliveries are refused.
        func abandon() -> Unchecked<Session>? {
            lock.withLock {
                abandoned = true
                defer { session = nil }
                return session
            }
        }
    }

    private struct ReopenTimedOut: LocalizedError {
        var errorDescription: String? { "the capture did not start in time" }
    }

    /// Lets a non-Sendable SDK result cross back into the actor; it is used from the actor only.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Swift 6.2 refuses to hand the non-Sendable `SCShareableContent` from the SDK's async
    /// method straight into an actor; fetching it in a nonisolated helper sidesteps that.
    /// Off-screen windows are listed too: the HUD is ordered in only after capture has started,
    /// and it must already be in the exclusion list then.
    private nonisolated static func shareableContent() async throws -> Unchecked<SCShareableContent> {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return Unchecked(value: content)
    }

    /// Same reason: awaiting `stopCapture()` on actor-owned stream state counts as sending it.
    private nonisolated static func stopCapture(_ stream: Unchecked<SCStream>) async throws {
        try await stream.value.stopCapture()
    }

    /// Same reason as `stopCapture`.
    private nonisolated static func startCapture(_ stream: Unchecked<SCStream>) async throws {
        try await stream.value.startCapture()
    }

    /// Builds the content filter for `target`; for a region also returns its source rect (display points).
    /// `excludedWindows` are kept out of display and region recordings.
    private static func filter(
        for target: CaptureTarget, in content: SCShareableContent, excluding excludedWindows: [SCWindow]
    ) throws -> (filter: SCContentFilter, sourceRect: CGRect?) {
        switch target {
        case .display(let displayID):
            guard
                let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first
            else { throw RecorderError.noDisplay }
            return (SCContentFilter(display: display, excludingWindows: excludedWindows), nil)
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.windowGone
            }
            return (SCContentFilter(desktopIndependentWindow: window), nil)
        case .region(let displayID, let rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.noDisplay
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            guard let source = CaptureTarget.sourceRect(rect, displaySize: filter.contentRect.size) else {
                throw RecorderError.noDisplay
            }
            return (filter, source)
        }
    }

    private func beginSession(_ take: Take, index: Int) async throws -> Session {
        let options = take.options
        if options.microphone {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecorderError.microphonePermissionDenied
            }
        }
        let content: SCShareableContent
        do {
            content = try await Self.shareableContent().value
        } catch {
            throw RecorderError.screenPermissionDenied
        }
        let requested = await excludedWindows()
        let (matched, missing) = Self.excludedWindowIDs(
            requested: requested, available: content.windows.map(\.windowID))
        if !missing.isEmpty {
            log("Recorder: windows \(missing) not in shareable content; they will not be excluded")
        }
        let ids = Set(matched)
        let (filter, sourceRect) = try Self.filter(
            for: take.target, in: content, excluding: content.windows.filter { ids.contains($0.windowID) })
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = Self.baseConfiguration(options)
        let captured = sourceRect?.size ?? filter.contentRect.size
        // HEVC rejects odd dimensions; outputSize keeps them even.
        let size = options.quality.resolution.outputSize(
            forNative: CGSize(width: captured.width * scale, height: captured.height * scale))
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        // Explicitly the default input of this moment: a segment opened after a switch uses the new device.
        let microphone = options.microphone ? DefaultInputObserver.currentDefaultInput() : nil
        if let uid = microphone?.uid { configuration.microphoneCaptureDeviceID = uid }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(take.stem).seg\(index).mp4")
        let bitrate = RecordingQuality.bitrate(
            width: configuration.width, height: configuration.height, fps: options.quality.fps,
            preset: options.quality.bitrate)
        let writer = try RecordingWriter(
            url: url, width: configuration.width, height: configuration.height, fps: options.quality.fps,
            videoBitrate: bitrate, systemAudio: options.systemAudio, microphone: options.microphone, log: log)
        let output = StreamOutput(writer: writer, log: log)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try output.attach(to: stream, systemAudio: options.systemAudio, microphone: options.microphone)
            try await Self.startCapture(Unchecked(value: stream))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Session(
            stream: stream, writer: writer, fileURL: url, output: output, index: index, bitrate: bitrate,
            microphoneUID: microphone?.uid, microphoneName: microphone?.name)
    }

    /// Everything but the size: frame rate, cursor, audio, and 420v BT.709 frames for the HEVC encoder.
    private static func baseConfiguration(_ options: RecorderOptions) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.quality.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // BT.709 end to end, matching the writer's colour tags, so the encoder converts nothing.
        configuration.colorSpaceName = CGColorSpace.itur_709
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.microphone
        if options.systemAudio {
            configuration.sampleRate = RecordingWriter.audioSampleRate
            configuration.channelCount = 2
        }
        return configuration
    }

    /// Closes the open segment, if any, and returns every segment. A segment that does not close in time
    /// surfaces as `stopTimedOut` carrying all segments, so finishing them can be retried.
    public func stop() async throws -> [URL] {
        await takeOverFromRoll()
        let session: Session?
        switch state {
        case .recording(let current): session = current
        case .paused, .rolling, .interrupted: session = nil
        default: throw RecorderError.notRecording
        }
        state = .stopping
        follower.stopped()
        var segments = take?.segments ?? []
        let timedOut = !unfinished.isEmpty
        defer {
            state = .idle
            take = nil
            unfinished = []
        }
        if let session {
            do {
                try await end(session)
            } catch RecorderError.stopTimedOut {
                throw RecorderError.stopTimedOut(segments: segments + [session.fileURL])
            }
            segments.append(session.fileURL)
        }
        if timedOut { throw RecorderError.stopTimedOut(segments: segments) }
        return segments
    }

    /// Stops the stream (bounded by `stopCaptureTimeout`, a stuck stop is logged and skipped) and then always
    /// closes the segment file, so it gets its index even when the stream hangs; both together are bounded
    /// by `stopTimeout`. Frames stop at the moment of the call; a still screen is held until then. A stream
    /// that stopped with an error (the recorded window closed, a display was unplugged) is only logged: the
    /// closed file is a good recording up to that point.
    private func end(_ session: Session) async throws {
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        let stream = Unchecked(value: session.stream)
        let writer = session.writer
        let log = self.log
        try await Deadline.run(
            timeout: Self.stopTimeout, error: RecorderError.stopTimedOut(segments: [session.fileURL])
        ) {
            do {
                try await Deadline.run(timeout: Self.stopCaptureTimeout, error: StopCaptureTimedOut()) {
                    try await Self.stopCapture(stream)
                }
            } catch is StopCaptureTimedOut {
                log(
                    "Recorder: stopping the capture took over \(Self.stopCaptureTimeout), closing the file anyway"
                )
            } catch {
                log("Recorder: stopping the capture failed: \(error.localizedDescription)")
            }
            _ = try await writer.finish(at: stopTime)
        }
        let bytes = (try? session.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log(
            RecordingWriter.summaryLine(
                segment: session.index, stats: writer.stats, bytes: bytes, bitrate: session.bitrate))
        if let error = session.output.streamError {
            log(
                "Recorder: segment \(session.index) kept although the capture stopped early: \(error.localizedDescription)"
            )
        }
    }

    private struct StopCaptureTimedOut: Error {}

}

/// Receives the stream's sample buffers on one serial queue and hands them to the segment's writer; keeps
/// the error the stream stopped with, if any.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: RecordingWriter
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "QuickTube.Recorder.samples", qos: .userInteractive)
    private let lock = NSLock()
    private var failure: Error?

    init(writer: RecordingWriter, log: @escaping @Sendable (String) -> Void) {
        self.writer = writer
        self.log = log
    }

    /// Screen always, system audio and microphone when recorded.
    func attach(to stream: SCStream, systemAudio: Bool, microphone: Bool) throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    /// The error the stream stopped with, if it did.
    var streamError: Error? { lock.withLock { failure } }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: writer.append(screen: sampleBuffer)
        case .audio: writer.append(audio: sampleBuffer, kind: .system)
        case .microphone: writer.append(audio: sampleBuffer, kind: .microphone)
        @unknown default: return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error }
        log("Recorder: the capture stopped: \(error.localizedDescription)")
    }
}

/// Runs an operation that may never return (a stuck stream or writer) with a time limit: past `timeout`
/// the caller gets `error` and the operation is left to finish on its own.
enum Deadline {
    static func run(
        timeout: Duration, error timeoutError: Error, operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let gate = Gate()
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.set(continuation)
            Task {
                do {
                    try await operation()
                    gate.resume(with: nil)
                } catch {
                    gate.resume(with: error)
                }
            }
            timer = Task {
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                gate.resume(with: timeoutError)
            }
        }
    }

    /// Resumes its continuation once; later results are ignored.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        func set(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(with error: Error?) {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { continuation = nil }
                return continuation
            }
            if let error { pending?.resume(throwing: error) } else { pending?.resume() }
        }
    }
}
