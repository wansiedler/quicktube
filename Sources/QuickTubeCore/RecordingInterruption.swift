import Foundation

/// Why the recorder stopped capturing on its own. The recording is then paused: resuming opens a new
/// segment, stopping keeps what was recorded.
public enum RecordingInterruption: Sendable, Equatable {
    /// A microphone switch closed the segment but could not open the next one.
    case microphoneSwitchFailed
    /// The stream stopped by itself, e.g. the recorded display was unplugged or went to sleep.
    case displayLost

    /// Short, for the log and the start of the notification.
    public var reason: String {
        switch self {
        case .microphoneSwitchFailed: "Microphone switch failed"
        case .displayLost: "The display went away"
        }
    }

    /// What the user is told.
    public var notification: String {
        switch self {
        case .microphoneSwitchFailed: "\(reason) — recording paused; press pause to resume"
        case .displayLost: "\(reason) — recording paused; resume when it is back"
        }
    }
}
