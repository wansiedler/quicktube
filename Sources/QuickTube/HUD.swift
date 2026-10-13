import AppKit
import QuickTubeCore
import SwiftUI

/// Small always-on-top status pill at the bottom of the screen under the cursor.
/// It never takes focus, and the recorder excludes it from capture by `windowNumber`.
@MainActor
final class HUDController {
    private let state: AppState
    private let panel: NSPanel
    private let hosting: NSHostingView<HUDView>
    private var hideTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        hosting = NSHostingView(rootView: HUDView(state: state, maxWidth: 480))
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
        // Invisible to every screen capture (Zoom, Meet, QuickTime), not only to QuickTube's own.
        panel.sharingType = .none
        panel.contentView = hosting
        observe()
    }

    /// The panel's window-server ID, for the recorder's exclusion list.
    var windowNumber: CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    /// Re-arms after every change: `withObservationTracking` fires once per mutation.
    private func observe() {
        withObservationTracking {
            _ = state.phase
            _ = state.uploadStage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.phaseChanged()
                self.observe()
            }
        }
    }

    private func phaseChanged() {
        hideTask?.cancel()
        hideTask = nil
        switch state.phase {
        case .idle:
            panel.orderOut(nil)
        case .recording, .paused, .uploading:
            show()
        case .done:
            show()
            hide(after: .seconds(6))
        case .failed:
            show()
            hide(after: .seconds(10))
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
        } else {
            maxWidth = 480
        }
        hosting.rootView = HUDView(state: state, maxWidth: maxWidth)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func hide(after delay: Duration) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

struct HUDView: View {
    let state: AppState
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .idle:
                EmptyView()
            case .recording:
                Circle().fill(Color.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    reserving("Recording 888:88") {
                        Text("Recording \(clock(state.recordedDuration(at: context.date)))")
                    }
                }
            case .paused:
                // The timer stands still: no TimelineView, the recorded time does not grow while paused.
                reserving("Paused ⏸ 888:88") {
                    Text("Paused ⏸ \(clock(state.recordedDuration(at: Date())))")
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
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: maxWidth)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(6)
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
