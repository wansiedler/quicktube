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
                Picker("Capture", selection: $model.settings.captureMode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Quality", selection: $model.settings.quality.resolution) {
                    ForEach(RecordingQuality.Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Frame rate", selection: $model.settings.quality.fps) {
                    ForEach(RecordingQuality.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("System audio", isOn: $model.settings.systemAudioEnabled)
                Toggle("Microphone", isOn: $model.settings.microphoneEnabled)
                Text(
                    "Select area and Select window show a chooser first: drag an area or click a window, Esc cancels. "
                        + "System audio records other apps' sound, never QuickTube's own."
                )
                .font(.callout).foregroundStyle(.secondary)
                Toggle(
                    "Pause and resume (\(AppModel.pauseCombo.label))",
                    isOn: Binding(
                        get: { model.settings.pauseEnabled },
                        set: { model.setPauseEnabled($0) }))
                Stepper(
                    "Trim start: \(seconds(model.settings.trimHeadSeconds))",
                    value: $model.settings.trimHeadSeconds, in: 0...3, step: 0.5)
                Stepper(
                    "Trim end: \(seconds(model.settings.trimTailSeconds))",
                    value: $model.settings.trimTailSeconds, in: 0...3, step: 0.5)
                Text("Trim end removes the stop-shortcut press. At least half a second is always kept.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Title template", text: $model.settings.titleTemplate)
                Text(
                    "Names the file and the upload. {date} is the start time, {app} the frontmost app, {display} the screen name."
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    "Applies to the next recording. 1080p at 30 fps is about 12 MB per minute; native 6K at 60 fps about 55 MB."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Camera") {
                Toggle(
                    "Camera bubble",
                    isOn: Binding(
                        get: { model.settings.cameraEnabled },
                        set: { model.setCameraEnabled($0) }))
                Toggle("Always on", isOn: $model.settings.cameraAlwaysOn)
                    .disabled(!model.settings.cameraEnabled)
                Picker("Size", selection: $model.settings.cameraSize) {
                    ForEach(CameraSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Corner", selection: $model.settings.cameraCorner) {
                    ForEach(Corner.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(
                    "A round camera view shown while recording, or all the time with Always on. "
                        + "It is part of the recording, in the chosen corner of the display or selected area; "
                        + "drag it anywhere. Window recordings capture only that window, so they never "
                        + "contain the bubble."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Keep recent links", isOn: $model.settings.historyEnabled)
                HStack {
                    Text("The last 20 uploaded links, under Recent Links in the menu.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.state.clearHistory() }
                        .disabled(model.state.history.isEmpty)
                }
            }
            Section("Overlays") {
                Toggle("Highlight clicks", isOn: $model.settings.clickHighlightEnabled)
                HStack {
                    Toggle("Show keystrokes", isOn: $model.settings.keystrokeOverlayEnabled)
                        .disabled(model.inputMonitoringStatus != .granted)
                    Spacer()
                    switch model.inputMonitoringStatus {
                    case .granted:
                        EmptyView()
                    case .notDetermined:
                        Button("Request") { model.requestInputMonitoring() }
                    case .denied:
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(Permissions.inputMonitoringPane)
                        }
                    }
                }
                Toggle("Show overlays in recording", isOn: $model.settings.overlaysInRecording)
                Text(
                    "While recording, a ring marks each click and a pill above the status bar shows the last "
                        + "key combo. Keystrokes need Input Monitoring. With \"Show overlays in recording\" off "
                        + "you still see them, but the video does not."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Files") {
                Toggle("Move to Trash after upload", isOn: $model.settings.deleteAfterUpload)
                Stepper(
                    value: $model.settings.deleteOlderThanDays, in: 0...365
                ) {
                    Text(
                        model.settings.deleteOlderThanDays == 0
                            ? "Trash old recordings: never"
                            : "Trash recordings older than \(model.settings.deleteOlderThanDays) days")
                }
                Text(
                    "Recordings go to the Trash, not away for good. Old ones are trashed when QuickTube starts."
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
                permissionRow(
                    "Camera", status: model.cameraStatus, pane: Permissions.cameraPane,
                    request: { model.requestCamera() })
                permissionRow(
                    "Input Monitoring", status: model.inputMonitoringStatus,
                    pane: Permissions.inputMonitoringPane,
                    request: { model.requestInputMonitoring() })
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
                TextField("Channel (@name or -100… id), or your user id", text: $model.telegramChat)
                HStack {
                    Button("Save Telegram") { model.saveTelegram() }
                    Spacer()
                    Text(model.telegramConfigured ? "Configured" : "Not set up").foregroundStyle(.secondary)
                }
                Toggle("Compress to fit the limit", isOn: $model.settings.telegramCompressToFit)
                Toggle("Allow downscaling when compressing", isOn: $model.settings.telegramAllowDownscale)
                Text("Off: compression only lowers video and audio quality, the frame size stays.")
                    .font(.callout).foregroundStyle(.secondary)
                Stepper(
                    "Limit (MB): \(model.settings.telegramLimitMB)", value: $model.settings.telegramLimitMB,
                    in: 10...2000, step: 10)
                Text(
                    "Create a bot with @BotFather, add it to your channel as admin. The Bot API accepts files "
                        + "up to 50 MB; raise the limit only for a self-hosted Bot API server. Larger recordings "
                        + "are re-encoded to fit when compression is on."
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

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
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
