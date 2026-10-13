import AppKit
import QuickTubeCore
import UniformTypeIdentifiers
import UserNotifications

/// Clipboard plus a user notification. Without a bundle (swift run) it logs instead.
@MainActor
final class AppNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    /// Runs after every failure, once AppState has recorded it.
    var onFailure: (@MainActor () -> Void)?

    func linkReady(_ url: URL, isUnlisted: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if url.isFileURL {
            fileReady(url, on: pasteboard)
            return
        }
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

    /// A local file: its file URL goes on the pasteboard and Finder shows it selected. A GIF also puts its
    /// data there, so it pastes as a file in Finder and as an image in chat apps; the recording itself
    /// ("Save only") is a video, too large to read for the pasteboard.
    /// The GIF is read off the main thread; a large one would otherwise stall the UI.
    private func fileReady(_ url: URL, on pasteboard: NSPasteboard) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let isGIF = url.pathExtension.lowercased() == "gif"
        post(
            title: AppState.doneText(link: url, destination: isGIF ? .gif : .local),
            body: url.lastPathComponent)
        guard isGIF else {
            pasteboard.writeObjects([url as NSURL])
            return
        }
        Task {
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if let data {
                item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
    }

    func failed(_ message: String) {
        post(title: "QuickTube", body: message)
        onFailure?()
    }

    /// Also installs self as delegate so banners show while QuickTube is the active app.
    func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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
