import CoreGraphics
import Foundation

/// What a recording captures. Pause/resume reuses the same target for every segment.
public enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// `rect` is in the display's points, origin top-left (like `CGDisplayBounds`, relative to the display).
    case region(display: CGDirectDisplayID, rect: CGRect)

    /// Selections smaller than this (points, either side) are treated as a stray click.
    public static let minimumRegionSide: CGFloat = 10

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

    /// A region from a selection drawn in AppKit view coordinates (origin bottom-left) on a screen of
    /// `screenSize` points. Clamped to the screen and widened to whole points; nil when the visible part
    /// is smaller than `minimumRegionSide` on either side.
    public static func region(
        display: CGDirectDisplayID, selection: CGRect, screenSize: CGSize
    ) -> CaptureTarget? {
        let flipped = CGRect(
            x: selection.minX, y: screenSize.height - selection.maxY,
            width: selection.width, height: selection.height)
        guard let rect = sourceRect(flipped, displaySize: screenSize) else { return nil }
        return .region(display: display, rect: rect)
    }

    /// `rect` clamped to a display of `displaySize` points and widened to whole points; nil when the
    /// visible part is smaller than `minimumRegionSide` on either side.
    public static func sourceRect(_ rect: CGRect, displaySize: CGSize) -> CGRect? {
        let visible = rect.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !visible.isNull, visible.width >= minimumRegionSide, visible.height >= minimumRegionSide
        else { return nil }
        return visible.integral.intersection(CGRect(origin: .zero, size: displaySize))
    }
}

/// Lets the user choose what to record; nil means the choice was cancelled.
@MainActor
public protocol CaptureTargetPicker: AnyObject {
    func pick(mode: CaptureMode) async -> CaptureTarget?
}
