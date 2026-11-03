import Foundation

/// Decides how a recording follows a change of the system default input device. ScreenCaptureKit binds
/// its microphone to a device when the stream starts, so a change mid-recording (headphones plugged in)
/// is applied first live, by updating the stream's configuration, and, when no microphone sample arrives
/// within `grace` after that, by rolling over to a new segment, which opens the capture on the new device.
///
/// Pure state: the caller feeds it events and times (host clock seconds) and carries out the actions.
public struct MicrophoneFollower: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle, recording, paused
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Point the live stream's microphone at the device with this UID.
        case updateConfiguration(uid: String)
        /// Close the segment and open the next one; it captures the current default input.
        case rollSegment
    }

    /// How long after a live update a microphone sample must arrive before the segment is rolled.
    public static let grace: TimeInterval = 1.5

    public private(set) var phase = Phase.idle
    /// The device the capture is (or, while paused, will be) asked to use; nil when unknown.
    public private(set) var configuredUID: String?
    /// Since when a microphone sample is awaited, after a live update.
    private var awaitingSince: TimeInterval?

    public init() {}

    /// Whether a live update waits for its first microphone sample.
    public var isAwaitingSample: Bool { awaitingSince != nil }

    /// A segment started capturing the device with `uid`.
    public mutating func began(uid: String?) {
        phase = .recording
        configuredUID = uid
        awaitingSince = nil
    }

    /// The segment closed for a pause; the next one opens on the default input of that moment.
    public mutating func paused() {
        phase = .paused
        awaitingSince = nil
    }

    public mutating func stopped() {
        self = MicrophoneFollower()
    }

    /// The default input changed to `uid`. Repeated reports of the configured device are ignored, so rapid
    /// changes coalesce: only a different device asks for another update, and restarts the grace period.
    public mutating func deviceChanged(uid: String, at now: TimeInterval) -> Action {
        guard uid != configuredUID else { return .none }
        switch phase {
        case .idle:
            return .none
        case .paused:
            configuredUID = uid
            return .none
        case .recording:
            configuredUID = uid
            awaitingSince = now
            return .updateConfiguration(uid: uid)
        }
    }

    /// The live update returned; the grace period counts from here, so samples the old device delivered
    /// while it was being applied do not count.
    public mutating func configurationApplied(at now: TimeInterval) {
        guard awaitingSince != nil else { return }
        awaitingSince = now
    }

    /// The live update was refused: roll at once.
    public mutating func updateFailed() -> Action {
        guard phase == .recording, awaitingSince != nil else { return .none }
        awaitingSince = nil
        return .rollSegment
    }

    /// A microphone sample arrived at `time`; one after the update confirms it.
    public mutating func microphoneSampleArrived(at time: TimeInterval) -> Action {
        if let since = awaitingSince, time >= since { awaitingSince = nil }
        return .none
    }

    /// Rolls the segment once the grace period passed without a microphone sample.
    public mutating func tick(now: TimeInterval) -> Action {
        guard phase == .recording, let since = awaitingSince, now - since >= Self.grace else { return .none }
        awaitingSince = nil
        return .rollSegment
    }
}
