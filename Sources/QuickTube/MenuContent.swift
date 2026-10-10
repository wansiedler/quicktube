import AppKit
import QuickTubeCore
import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusText)
        Divider()
        switch model.state.phase {
        case .recording, .paused:
            if model.state.phase == .paused {
                Button("Resume") { Task { await model.state.resume() } }
            } else if model.settings.pauseEnabled {
                Button("Pause") { Task { await model.state.pause() } }
            }
            Button("Stop → Save only") { Task { await model.state.toggle(destination: .local) } }
            Button("Stop and Upload to YouTube") { Task { await model.state.toggle(destination: .youtube) } }
            Button("Stop and Send to Telegram") { Task { await model.state.toggle(destination: .telegram) } }
            Button("Stop and Upload to Google Drive") {
                Task { await model.state.toggle(destination: .drive) }
            }
            Button("Stop and Send to Slack") { Task { await model.state.toggle(destination: .slack) } }
            Button("Stop → Vimeo") { Task { await model.state.toggle(destination: .vimeo) } }
            if model.settings.gifEnabled {
                Button("Stop and Make GIF") { Task { await model.state.toggle(destination: .gif) } }
            }
        case .uploading:
            Button("Uploading…") {}.disabled(true)
        default:
            Button("Start Recording") { Task { await model.state.toggle() } }
        }
        if case .failed(_, let file) = model.state.phase {
            if model.state.canRetry {
                Button(file != nil ? "Retry Upload" : "Retry") { Task { await model.state.retry() } }
            }
            if let pane = privacyPane {
                Button("Open Privacy Settings…") { NSWorkspace.shared.open(pane) }
            }
        }
        if model.state.lastLink != nil {
            Button("Copy Last Link") { model.copyLastLink() }
        }
        if model.settings.historyEnabled {
            Menu("Recent Links") {
                ForEach(model.state.history) { item in
                    Button("\(item.title) — \(item.destination.label)") {
                        model.copyToPasteboard(item.link)
                    }
                }
                if !model.state.history.isEmpty { Divider() }
                Button("Clear History") { model.state.clearHistory() }
                    .disabled(model.state.history.isEmpty)
            }
        }
        Divider()
        Picker("Capture: \(model.settings.captureMode.label)", selection: $model.settings.captureMode) {
            ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker(
            "Quality: \(model.settings.quality.resolution.label)",
            selection: $model.settings.quality.resolution
        ) {
            ForEach(RecordingQuality.Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Frame rate: \(model.settings.quality.fps) fps", selection: $model.settings.quality.fps) {
            ForEach(RecordingQuality.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
        }
        Toggle(
            "Camera",
            isOn: Binding(
                get: { model.settings.cameraEnabled },
                set: { model.setCameraEnabled($0) }))
        Divider()
        Button("Open Recordings Folder") { model.openRecordingsFolder() }
        Button("Open Log File") { NSWorkspace.shared.open(DiagnosticsLog.url) }
        Divider()
        Button("Check for Updates…") { model.checkForUpdates() }
            .disabled(!model.updater.isAvailable)
        Button("Settings…") {
            // A menu bar app is never active, so the window would open behind others.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit QuickTube") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    /// The System Settings pane that fixes the current permission failure, if any.
    private var privacyPane: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch model.state.failureKind {
        case .screenPermission: return URL(string: base + "Privacy_ScreenCapture")
        case .microphonePermission: return URL(string: base + "Privacy_Microphone")
        default: return nil
        }
    }

    private var shortcutSummary: String {
        model.visibleDestinations.map { "\(model.combo(for: $0).label) \($0.label)" }.joined(separator: " · ")
    }

    private var statusText: String {
        switch model.state.phase {
        case .idle: "Ready — " + shortcutSummary
        case .recording: "Recording… stop with " + shortcutSummary
        case .paused: "Paused — resume with \(AppModel.pauseCombo.label), stop with " + shortcutSummary
        case .uploading(let progress): AppState.uploadText(stage: model.state.uploadStage, progress: progress)
        case .done(let link) where link.isFileURL:
            "\(model.state.destination == .local ? "Saved" : "GIF saved"): \(link.lastPathComponent)"
        case .done(let link): "Uploaded: \(link.absoluteString)"
        case .failed(let message, _): "Failed: \(message)"
        }
    }
}

extension Phase {
    var symbolName: String {
        switch self {
        case .idle, .done: "record.circle"
        case .recording: "stop.circle.fill"
        case .paused: "pause.circle"
        case .uploading: "arrow.up.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}
