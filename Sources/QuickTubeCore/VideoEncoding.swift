import AVFoundation
import Foundation
import VideoToolbox

/// Encoder settings and error classification shared by `VideoTranscoder` (file → file) and
/// `RecordingWriter` (live capture → file).
public enum VideoEncoding {
    /// Requires the hardware encoder so a slow software fallback cannot happen silently; callers retry
    /// without it (and logs that) when the machine has none.
    public static func encoderSpecification() -> [String: Any] {
        [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
    }

    /// The software encoder's spec: hardware explicitly off, so "using software" is what actually happens.
    public static func softwareEncoderSpecification() -> [String: Any] {
        [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
    }

    /// The encoder settings: the bitrate and no frame reordering (no B-frame delay), since a Telegram copy
    /// only has to fit the limit, not look its best; H.264 also gets the High profile (auto level). The
    /// `hardware` encoder also gets speed over quality and a hard bitrate cap (bitrate/8 bytes per 1 s window,
    /// because the average alone overshoots at 6K). Apple's software HEVC and H.264 encoders reject both
    /// VideoToolbox keys with an uncatchable exception, so they get only the AVFoundation ones.
    ///
    /// `realTime` (live recording) adds a key frame at least every 2 s and, on the hardware encoder,
    /// `RealTime`; its cap is 2× the average per 1 s window, so a burst of motion after a still screen
    /// keeps its detail while the average still holds.
    public static func compressionProperties(
        bitrate: Int, fps: Double, hardware: Bool, codec: VideoCodec = .hevc, realTime: Bool = false
    ) -> [String: Any] {
        var properties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 { properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if realTime { properties[AVVideoMaxKeyFrameIntervalDurationKey] = 2 }
        if hardware {
            let peakBytes = realTime ? bitrate / 4 : bitrate / 8
            properties[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
            properties[kVTCompressionPropertyKey_DataRateLimits as String] = [
                NSNumber(value: peakBytes), NSNumber(value: 1.0),
            ]
            if realTime { properties[kVTCompressionPropertyKey_RealTime as String] = true }
        }
        if fps > 0 { properties[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded()) }
        return properties
    }

    /// OSStatus / AVError codes that mean "this encoder cannot be used here": none on the machine
    /// (kVTCouldNotFindVideoEncoderErr -12908), none free now (kVTVideoEncoderNotAvailableNowErr -12915), no
    /// instance could be created (kVTCouldNotCreateInstanceErr -12907), or the hardware one refusing the session,
    /// as for sizes beyond its limit (kVTInvalidSessionErr -12903, seen under AVFoundation -11800).
    static let encoderUnavailableCodes: Set<Int> = [
        Int(kVTCouldNotFindVideoEncoderErr), Int(kVTVideoEncoderNotAvailableNowErr),
        Int(kVTCouldNotCreateInstanceErr), Int(kVTInvalidSessionErr),
        AVError.Code.encoderNotFound.rawValue, AVError.Code.encoderTemporarilyUnavailable.rawValue,
    ]

    /// Pure: true when `error` or one of its underlying errors says the video encoder is unavailable.
    public static func isEncoderUnavailable(_ error: Error?) -> Bool {
        var current = error.map { $0 as NSError }
        while let nsError = current {
            let osStatusLike =
                nsError.domain == NSOSStatusErrorDomain || nsError.domain == AVFoundationErrorDomain
            if osStatusLike && encoderUnavailableCodes.contains(nsError.code) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Pure: whether a failed start of the writer is retried with the software encoder. Only the hardware attempt
    /// retries, when the writer rejected its video input (the hardware settings) or `startWriting` failed with an
    /// encoder-unavailable error; the software attempt's failures are final.
    public static func shouldRetryInSoftware(hardware: Bool, inputRejected: Bool, error: Error?) -> Bool {
        hardware && (inputRejected || isEncoderUnavailable(error))
    }

    /// The error and its underlying chain as one line, e.g. "Cannot Encode (AVFoundationErrorDomain -11800
    /// ← NSOSStatusErrorDomain -12903)".
    public static func describe(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        var codes: [String] = []
        var current: NSError? = error as NSError
        while let nsError = current {
            codes.append("\(nsError.domain) \(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) (\(codes.joined(separator: " ← ")))"
    }
}

extension AVAssetWriter {
    /// `finishWriting()` with a hand-written bridge that resumes once. Built with the Xcode 26 SDK and run
    /// on the macOS 15 CI runner, the completion handler can run twice (from NSOperation's KVO observer),
    /// and the compiler-generated bridge then resumes its continuation a second time: SIGSEGV in
    /// `swift_continuation_resume`, or SIGTRAP. Later calls of the handler are ignored here.
    public func finishWritingOnce() async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWriting {
                if once.claim() { continuation.resume() }
            }
        }
    }
}

/// True from `claim()` exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
