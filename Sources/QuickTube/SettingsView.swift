import AppKit
import QuickTubeCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var listening: Destination?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) })
                )
                .disabled(!LaunchAtLogin.isAvailable)
                if let message = model.launchAtLoginMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Recording") {
                Picker("Quality", selection: $model.quality.resolution) {
                    ForEach(RecordingQuality.Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $model.quality.fps) {
                    ForEach(RecordingQuality.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Text(
                    "Applies to the next recording. 1080p at 30 fps is about 12 MB per minute; native 6K at 60 fps about 55 MB."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permissionRow(
                    "Microphone", status: model.microphoneStatus, pane: Permissions.microphonePane,
                    request: { model.requestMicrophone() })
                permissionRow(
                    "Screen Recording", status: model.screenRecordingStatus,
                    pane: Permissions.screenRecordingPane,
                    request: { model.requestScreenRecording() })
                Text("macOS applies a new Screen Recording grant after QuickTube is relaunched.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Google") {
                TextField("OAuth client ID", text: $model.clientID)
                SecureField("OAuth client secret", text: $model.clientSecret)
                HStack {
                    Button("Save client") { model.saveClient() }
                    Spacer()
                    if model.signedIn {
                        Text("Signed in").foregroundStyle(.secondary)
                        Button("Sign out") { model.signOut() }
                    } else if model.signingIn {
                        Button("Cancel sign-in") { model.cancelSignIn() }
                    } else {
                        Button("Sign in with Google") { model.signIn() }
                    }
                }
                if let message = model.authMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Telegram") {
                SecureField("Bot token", text: $model.telegramToken)
                TextField("Channel (@name, -100… id) or your user id for a private chat", text: $model.telegramChat)
                HStack {
                    Button("Save Telegram") { model.saveTelegram() }
                    Spacer()
                    Text(model.telegramConfigured ? "Configured" : "Not set up").foregroundStyle(.secondary)
                }
                Text(
                    "Create a bot with @BotFather, add it to your channel as admin. Bots accept files up to 50 MB."
                )
                .font(.callout).foregroundStyle(.secondary)
                if let message = model.telegramMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Google Drive") {
                Text(
                    "Uses the Google sign-in above. Files go to a \"QuickTube\" folder and are shared as "
                        + "\"anyone with the link\". If you signed in before Drive support, sign out and in again."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Slack") {
                SecureField("Bot token (xoxb-…)", text: $model.slackToken)
                TextField("Channel ID (C…)", text: $model.slackChannel)
                HStack {
                    Button("Save Slack") { model.saveSlack() }
                    Spacer()
                    Text(model.slackConfigured ? "Configured" : "Not set up").foregroundStyle(.secondary)
                }
                Text(
                    "Create a Slack app with the files:write scope, install it, invite the bot to the channel."
                )
                .font(.callout).foregroundStyle(.secondary)
                if let message = model.slackMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Shortcuts") {
                shortcutRow("Record → YouTube", destination: .youtube)
                shortcutRow("Record → Telegram", destination: .telegram)
                shortcutRow("Record → Google Drive", destination: .drive)
                shortcutRow("Record → Slack", destination: .slack)
                Text(
                    "Hold ⌘ or ⌃ (plus any other modifiers). Either shortcut starts a recording; the one you press to stop picks the destination."
                )
                .font(.callout).foregroundStyle(.secondary)
                if let message = model.hotkeyMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: Self.idealHeight)
        .onAppear {
            Self.fitWindowToScreen()
            model.refreshAuth()
            model.refreshTelegram()
            model.refreshSlack()
            model.refreshLaunchAtLogin()
            model.refreshPermissions()
        }
        .onDisappear { stopListening() }
    }

    /// As tall as the screen allows; the grouped form scrolls if the content is taller.
    private static var idealHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(420, screen - 60)
    }

    /// Sizes the window to its content, capped at the screen height (then the form scrolls).
    /// macOS restores the last frame otherwise, so this runs on every open, after layout.
    private static func fitWindowToScreen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = NSApp.windows.first(where: { $0.title.hasSuffix("Settings") }),
                let screen = window.screen ?? NSScreen.main,
                let content = window.contentView
            else { return }
            let visible = screen.visibleFrame
            let chrome = window.frame.height - content.frame.height
            let wanted = (documentHeight(in: content) ?? idealHeight) + chrome
            var frame = window.frame
            frame.size.height = min(max(wanted, 420), visible.height - 40)
            frame.size.width = max(frame.width, 520)
            // Keep the top edge where it was; clamp the whole window onto the screen.
            frame.origin.y = window.frame.maxY - frame.height
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// The grouped form is an NSScrollView under the hood; its document view is the full content.
    private static func documentHeight(in view: NSView) -> CGFloat? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            return document.frame.height + scroll.contentInsets.top + scroll.contentInsets.bottom
        }
        for child in view.subviews {
            if let height = documentHeight(in: child) { return height }
        }
        return nil
    }

    @ViewBuilder
    private func shortcutRow(_ name: String, destination: Destination) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(model.combo(for: destination).label).font(.title3.monospaced())
            Button(listening == destination ? "Press keys…" : "Change") { startListening(destination) }
                .disabled(listening != nil)
        }
    }

    @ViewBuilder
    private func permissionRow(
        _ name: String, status: Permissions.Status, pane: URL, request: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(status.label)
                .foregroundStyle(status == .granted ? Color.secondary : Color.red)
            switch status {
            case .granted:
                EmptyView()
            case .notDetermined:
                Button("Request") { request() }
            case .denied:
                Button("Open System Settings") { NSWorkspace.shared.open(pane) }
            }
        }
    }

    private func startListening(_ destination: Destination) {
        listening = destination
        // Release the global hotkeys so pressing a current combo is captured, not acted on.
        model.suspendHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let combo = HotkeyManager.Combo(event: event) {
                model.setCombo(combo, for: destination)
            }
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if listening != nil {
            model.resumeHotkey()
        }
        listening = nil
    }
}
