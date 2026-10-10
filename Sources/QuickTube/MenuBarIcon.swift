import AppKit
import QuickTubeCore
import SwiftUI

/// Menu bar glyph per phase. Idle and done use template symbols that follow the
/// menu bar tint; recording draws a real red dot, which a template image cannot show.
@MainActor
enum MenuBarIcon {
    @ViewBuilder
    static func image(for phase: Phase) -> some View {
        switch phase {
        case .recording:
            Image(nsImage: recordingDot)
        default:
            Image(systemName: phase.symbolName)
        }
    }

    /// A red dot inside a thin ring, drawn at menu bar size; not a template image.
    private static let recordingDot: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            let ringPath = NSBezierPath(ovalIn: ring)
            ringPath.lineWidth = 1.5
            ringPath.stroke()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
