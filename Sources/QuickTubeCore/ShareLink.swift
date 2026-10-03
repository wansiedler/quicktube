import Foundation

public enum ShareLink {
    private static let base = URL(string: "https://youtu.be/")!

    /// The short link copied to the clipboard once an upload finishes.
    public static func url(forVideoID id: String) -> URL {
        base.appending(path: id)
    }
}
