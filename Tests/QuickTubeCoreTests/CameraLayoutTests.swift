import CoreGraphics
import QuickTubeCore
import Testing

@Suite struct CameraLayoutTests {
    // A secondary screen left of and below the primary one, as AppKit reports it.
    let screen = CGRect(x: -1440, y: -100, width: 1440, height: 875)

    @Test(arguments: [
        (Corner.bottomLeft, CGPoint(x: -1416, y: -76)),
        (Corner.bottomRight, CGPoint(x: -244, y: -76)),
        (Corner.topLeft, CGPoint(x: -1416, y: 531)),
        (Corner.topRight, CGPoint(x: -244, y: 531)),
    ])
    func originKeepsTheInsetFromBothEdges(corner: Corner, expected: CGPoint) {
        #expect(CameraLayout.origin(for: corner, size: 220, in: screen, inset: 24) == expected)
    }

    @Test func defaultInsetIs24Points() {
        let origin = CameraLayout.origin(
            for: .bottomLeft, size: 160, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(origin == CGPoint(x: 24, y: 24))
    }
}
