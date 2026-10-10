import CoreGraphics
import QuickTubeCore
import Testing

@Suite struct CaptureTargetTests {
    let screen = CGSize(width: 1512, height: 982)

    @Test func selectionIsFlippedToTopLeftPoints() {
        // AppKit view rect: origin bottom-left.
        let target = CaptureTarget.region(
            display: 5, selection: CGRect(x: 100, y: 82, width: 400, height: 300), screenSize: screen)
        #expect(target == .region(display: 5, rect: CGRect(x: 100, y: 600, width: 400, height: 300)))
    }

    @Test func selectionIsMadeIntegralAndClampedToTheScreen() {
        let target = CaptureTarget.region(
            display: 1, selection: CGRect(x: -20.4, y: 900.6, width: 120.9, height: 200), screenSize: screen)
        #expect(target == .region(display: 1, rect: CGRect(x: 0, y: 0, width: 101, height: 82)))
    }

    @Test(arguments: [
        CGRect(x: 10, y: 10, width: 9, height: 300),
        CGRect(x: 10, y: 10, width: 300, height: 9.5),
        CGRect(x: 2000, y: 10, width: 300, height: 300),
    ])
    func tinyOrOffscreenSelectionsAreRejected(selection: CGRect) {
        #expect(CaptureTarget.region(display: 1, selection: selection, screenSize: screen) == nil)
    }

    @Test func sourceRectIsClampedToTheDisplay() {
        let rect = CaptureTarget.sourceRect(
            CGRect(x: 1400, y: -10, width: 300, height: 100), displaySize: screen)
        #expect(rect == CGRect(x: 1400, y: 0, width: 112, height: 90))
        #expect(
            CaptureTarget.sourceRect(CGRect(x: 1600, y: 0, width: 10, height: 10), displaySize: screen) == nil
        )
    }

    @Test func regionOutputSizeScalesThePixelSizeAndStaysEven() {
        let size = RecordingQuality.Resolution.native.outputSize(
            forNative: CGSize(width: 301 * 2, height: 151 * 2))
        #expect(size == CGSize(width: 602, height: 302))
        let odd = RecordingQuality.Resolution.native.outputSize(forNative: CGSize(width: 301, height: 151))
        #expect(odd == CGSize(width: 300, height: 150))
    }
}
