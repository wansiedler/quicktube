import Foundation

/// Decides when a recording rolls over to a new segment for a change of the system default input.
/// ScreenCaptureKit binds its microphone to a device when the stream starts, so a change mid-recording
/// (headphones plugged in) is followed by closing the segment and opening the next one on the new device.
///
/// One roll at a time: changes that come while one runs coalesce into it, and when it is done one more
/// roll follows only if the default input is by then another device than the one rolled to. While paused
/// nothing is needed: resuming opens the capture on the default input of that moment.
///
/// Pure state: the caller feeds it events and carries out the actions.
public struct MicrophoneFollower: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, recording, paused
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Close the segment and open the next one; it captures the current default input.
        case rollSegment
    }

    public private(set) var phase = Phase.idle
    /// The device the open segment captures; nil when unknown.
    public private(set) var recordingUID: String?
    /// Whether a roll runs.
    public private(set) var isRolling = false

    public init() {}

    /// A segment started (or resumed) capturing the device with `uid`.
    public mutating func began(uid: String?) {
        phase = .recording
        recordingUID = uid
        isRolling = false
    }

    /// The segment closed for a pause.
    public mutating func paused() {
        phase = .paused
        isRolling = false
    }

    public mutating func stopped() {
        self = MicrophoneFollower()
    }

    /// The default input is now `uid`.
    public mutating func deviceChanged(uid: String) -> Action {
        guard phase == .recording, !isRolling, uid != recordingUID else { return .none }
        isRolling = true
        return .rollSegment
    }

    /// The roll opened the next segment on `rolledTo`; `currentDefault` is the default input now.
    public mutating func rollFinished(rolledTo: String?, currentDefault: String?) -> Action {
        began(uid: rolledTo)
        guard let currentDefault else { return .none }
        return deviceChanged(uid: currentDefault)
    }

    /// The roll could not open the next segment: nothing is captured until the recording is paused or
    /// stopped, so there is nothing to follow.
    public mutating func rollFailed() {
        paused()
    }
}
