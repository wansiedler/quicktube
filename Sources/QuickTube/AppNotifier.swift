import AppKit
import QuickTubeCore
import UserNotifications

/// Clipboard plus a user notification. Without a bundle (swift run) it logs instead.
@MainActor
final class AppNotifier: Notifier {
    func linkReady(_ url: URL, isUnlisted: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        if isUnlisted {
            post(title: "Link copied", body: url.absoluteString)
        } else {
            post(
                title: "Uploaded as PRIVATE — link copied",
                body: "YouTube locked the video to private because the API project is unverified. "
                    + url.absoluteString)
        }
    }

    func failed(_ message: String) {
        post(title: "QuickTube", body: message)
    }

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("\(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
