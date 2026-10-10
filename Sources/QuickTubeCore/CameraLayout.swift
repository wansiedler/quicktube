import CoreGraphics

/// Where the camera bubble sits; AppKit coordinates (origin bottom-left).
public enum CameraLayout {
    /// Gap between the bubble and the screen edges, in points.
    public static let inset: CGFloat = 24

    /// The bottom-left origin of a `size`×`size` bubble in `corner` of `screenFrame`, `inset` from both edges.
    public static func origin(
        for corner: Corner, size: CGFloat, in screenFrame: CGRect, inset: CGFloat = inset
    ) -> CGPoint {
        let left = screenFrame.minX + inset
        let right = screenFrame.maxX - inset - size
        let bottom = screenFrame.minY + inset
        let top = screenFrame.maxY - inset - size
        switch corner {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    /// Smallest bubble; an area too small for it gets none.
    public static let minimumSize: CGFloat = 48

    /// Size and inset for a bubble of `size` that stays wholly inside `area`: shrunk to the smaller side
    /// minus both insets, and when that is below `minimumSize`, the inset shrinks instead. Nil when the
    /// smaller side is under `minimumSize`.
    public static func fit(
        _ size: CGFloat, in area: CGRect, inset: CGFloat = inset
    ) -> (size: CGFloat, inset: CGFloat)? {
        let side = min(area.width, area.height)
        guard side >= minimumSize else { return nil }
        let inset = min(inset, (side - minimumSize) / 2)
        return (min(size, side - 2 * inset), inset)
    }

    /// A region of a display (`rect` in the display's points, origin top-left, as `CaptureTarget.region`
    /// holds it) in AppKit global coordinates, given the display's `NSScreen.frame`.
    public static func appKitRect(region rect: CGRect, onScreen screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + rect.minX, y: screenFrame.maxY - rect.maxY,
            width: rect.width, height: rect.height)
    }
}
