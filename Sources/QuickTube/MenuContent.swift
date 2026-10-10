import AppKit
import QuickTubeCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(statusText)
        Divider()
        switch model.state.phase {
        case .recording:
            Button("Stop Recording and Upload") { Task { await model.state.toggle() } }
        case .uploading:
            Button("Uploading…") {}.disabled(true)
        default:
            Button("Start Recording") { Task { await model.state.toggle() } }
        }
        if case .failed(_, let file) = model.state.phase {
            if file != nil {
                Button("Retry Upload") { Task { await model.state.retry() } }
            }
            if let pane = privacyPane {
                Button("Open Privacy Settings…") { NSWorkspace.shared.open(pane) }
            }
        }
        if model.state.lastLink != nil {
            Button("Copy Last Link") { model.copyLastLink() }
        }
        Button("Open Recordings Folder") { model.openRecordingsFolder() }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit QuickTube") { NSApplication.shared.terminate(nil) }
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

    private var statusText: String {
        switch model.state.phase {
        case .idle: "Ready — \(model.combo.label)"
        case .recording: "Recording… press \(model.combo.label) to stop"
        case .uploading(let progress): "Uploading \(Int(progress * 100))%"
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
        case .uploading: "arrow.up.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}
