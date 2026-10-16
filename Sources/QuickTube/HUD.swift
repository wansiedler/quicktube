import AppKit
import QuickTubeCore
import SwiftUI

/// Small always-on-top status pill at the top (or bottom) of the screen under the cursor.
/// It never takes focus, and the recorder excludes it from capture by `windowNumber`.
@MainActor
final class HUDController {
    private let state: AppState
    private let panel: NSPanel
    private let hosting: NSHostingView<HUDView>
    private var hideTask: Task<Void, Never>?
    /// The phase the pill was last placed for; background progress alone keeps a done/failed timer running.
    private var shownPhase: Phase?
    /// The done/failed pill timed out while background uploads still run; the pill shows those instead.
    private var expired = false

    init(state: AppState) {
        self.state = state
        hosting = NSHostingView(rootView: HUDView(state: state, maxWidth: 480, backgroundOnly: false))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            // Not deferred: the window exists (and has a number to exclude) before it is first shown.
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.sharingType = .none
        panel.contentView = hosting
        observe()
    }

    /// Invisible to every screen capture (Zoom, Meet, QuickTime) when on; the recorder excludes the
    /// panel by window ID either way, so QuickTube's own recording never shows it.
    var hiddenFromCapture: Bool = true {
        didSet { panel.sharingType = hiddenFromCapture ? .none : .readOnly }
    }

    /// Settings → Overlays "Status pill"; applied the next time the pill is placed.
    var position: HUDPosition = .top

    /// The panel's window-server ID, for the recorder's exclusion list.
    var windowNumber: CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    /// Re-arms after every change: `withObservationTracking` fires once per mutation.
    private func observe() {
        withObservationTracking {
            _ = state.phase
            _ = state.uploadStage
            _ = state.backgroundUploads
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.phaseChanged()
                self.observe()
            }
        }
    }

    private func phaseChanged() {
        let moved = state.phase != shownPhase
        shownPhase = state.phase
        switch state.phase {
        case .idle:
            cancelHide()
            showOrHideBackground()
        case .recording, .paused, .uploading:
            cancelHide()
            show()
        case .done, .failed:
            if moved {
                cancelHide()
                show()
                hide(after: delay(for: state.phase))
            } else if expired {
                showOrHideBackground()
            } else {
                // A background upload changed; re-measure and keep the running timer.
                show()
            }
        }
    }

    private func delay(for phase: Phase) -> Duration {
        if case .failed = phase { return .seconds(10) }
        return .seconds(6)
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
        expired = false
    }

    /// With background uploads left the pill shows them; otherwise it goes away.
    private func showOrHideBackground() {
        if state.backgroundUploads.isEmpty {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let underCursor = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        guard let screen = underCursor ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Errors get the whole screen width so the server's message is readable.
        let maxWidth: CGFloat
        if case .failed = state.phase {
            maxWidth = visible.width - 48
        } else if case .uploading = state.phase, state.uploadStage.contains(" · ") {
            // Compression details (before → after) need room.
            maxWidth = visible.width - 48
        } else if state.backgroundUploads.first?.stage.contains(" · ") == true {
            maxWidth = visible.width - 48
        } else {
            maxWidth = 480
        }
        hosting.rootView = HUDView(state: state, maxWidth: maxWidth, backgroundOnly: expired)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let y = position == .top ? visible.maxY - 24 - size.height : visible.minY + 24
        let origin = NSPoint(x: visible.midX - size.width / 2, y: y)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// After `delay` the done/failed pill goes, or makes way for the background uploads still running.
    private func hide(after delay: Duration) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.expired = true
            self.showOrHideBackground()
        }
    }
}

struct HUDView: View {
    let state: AppState
    let maxWidth: CGFloat
    /// Shows only the background uploads, whatever the phase: the done/failed pill timed out.
    let backgroundOnly: Bool

    var body: some View {
        HStack(spacing: 10) {
            if backgroundOnly {
                backgroundPill
            } else {
                phaseContent
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: maxWidth)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(6)
    }

    @ViewBuilder private var phaseContent: some View {
        switch state.phase {
        case .idle:
            backgroundPill
        case .recording:
            Circle().fill(Color.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                reserving("Recording 888:88" + backgroundSuffix.widest) {
                    Text(
                        "Recording \(clock(state.recordedDuration(at: context.date)))" + backgroundSuffix.text
                    )
                }
            }
        case .paused:
            // The timer stands still: no TimelineView, the recorded time does not grow while paused.
            reserving("Paused ⏸ 888:88" + backgroundSuffix.widest) {
                Text("Paused ⏸ \(clock(state.recordedDuration(at: Date())))" + backgroundSuffix.text)
            }
        case .uploading(let progress):
            ProgressView(value: progress).frame(width: 120)
            Text(AppState.uploadText(stage: state.uploadStage, progress: progress)).monospacedDigit()
        case .done(let link):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(AppState.doneText(link: link, destination: state.destination))
                .onTapGesture {
                    if link.isFileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([link])
                    } else {
                        NSWorkspace.shared.open(link)
                    }
                }
        case .failed(let message, _):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The first background upload as a normal uploading pill; empty without one.
    @ViewBuilder private var backgroundPill: some View {
        if let upload = state.backgroundUploads.first {
            ProgressView(value: upload.progress).frame(width: 120)
            Text(AppState.uploadText(stage: upload.stage, progress: upload.progress)).monospacedDigit()
        }
    }

    /// " · Uploading 43%" for the first background upload, and the same at 100% to reserve its width.
    private var backgroundSuffix: (text: String, widest: String) {
        guard let upload = state.backgroundUploads.first else { return ("", "") }
        return (
            " · " + AppState.uploadText(stage: upload.stage, progress: upload.progress),
            " · " + AppState.uploadText(stage: upload.stage, progress: 1)
        )
    }

    /// The panel is sized once when shown; the clock grows later ("9:59" → "10:00"), so the
    /// label reserves the width of the widest value it can reach instead of truncating.
    private func reserving(_ widest: String, @ViewBuilder _ label: () -> Text) -> some View {
        ZStack(alignment: .leading) {
            Text(widest).monospacedDigit().hidden()
            label().monospacedDigit()
        }
    }

    private func clock(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
