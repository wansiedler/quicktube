import CoreGraphics
import Foundation

/// What a recording captures. Pause/resume reuses the same target for every segment.
public enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)

    /// The display under the mouse pointer, else the main display.
    public static func displayUnderCursor() -> CaptureTarget {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(cursor, 1, &display, &count) == .success, count > 0 {
            return .display(display)
        }
        return .display(CGMainDisplayID())
    }
}
