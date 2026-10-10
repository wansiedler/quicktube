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
}
