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

    @Test func fitKeepsTheBubbleWhenThereIsRoom() {
        let fit = CameraLayout.fit(220, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(fit?.size == 220)
        #expect(fit?.inset == 24)
    }

    @Test func fitShrinksToTheSmallerSideMinusInsets() {
        // 300 - 2 × 24 = 252 < 300.
        let fit = CameraLayout.fit(300, in: CGRect(x: 50, y: 50, width: 900, height: 300))
        #expect(fit?.size == 252)
        #expect(fit?.inset == 24)
    }

    @Test(arguments: [CGFloat(48), 60, 95])
    func narrowAreasShrinkTheInsetSoTheBubbleStaysInside(side: CGFloat) throws {
        let area = CGRect(x: 10, y: 10, width: side, height: 500)
        let fit = try #require(CameraLayout.fit(160, in: area))
        #expect(fit.size >= CameraLayout.minimumSize)
        #expect(fit.size + 2 * fit.inset <= side)
        let origin = CameraLayout.origin(for: .topRight, size: fit.size, in: area, inset: fit.inset)
        #expect(origin.x >= area.minX && origin.x + fit.size <= area.maxX)
    }

    @Test func areasUnderTheMinimumGetNoBubble() {
        #expect(CameraLayout.fit(160, in: CGRect(x: 0, y: 0, width: 47, height: 400)) == nil)
    }

    @Test func regionIsFlippedIntoGlobalAppKitCoordinates() {
        // Display to the right of a primary screen, its top at AppKit y = 1100.
        let screenFrame = CGRect(x: 1512, y: 200, width: 1920, height: 900)
        let rect = CameraLayout.appKitRect(
            region: CGRect(x: 100, y: 50, width: 400, height: 300), onScreen: screenFrame)
        #expect(rect == CGRect(x: 1612, y: 750, width: 400, height: 300))
    }
}
