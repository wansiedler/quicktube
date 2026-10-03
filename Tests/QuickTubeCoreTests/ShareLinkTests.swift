import Foundation
import QuickTubeCore
import Testing

@Test func shareLinkUsesShortDomain() {
    #expect(ShareLink.url(forVideoID: "dQw4w9WgXcQ").absoluteString == "https://youtu.be/dQw4w9WgXcQ")
}
