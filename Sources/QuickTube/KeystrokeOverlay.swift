import AppKit
import Observation
import QuickTubeCore
import SwiftUI

/// A pill at the bottom centre of the screen, just above the HUD, showing the last key combo for
/// 1.5 s. The global key monitor needs Input Monitoring; the caller starts it only when granted.
/// The window stays ordered in (transparent while idle) from `start` to `stop`, so its number can be
/// excluded from capture.
@MainActor
final class KeystrokeOverlay {
    /// The HUD sits 24 pt above the bottom of the visible frame and is about 48 pt tall.
    private static let bottomInset: CGFloat = 24 + 48 + 12
    private static let size = NSSize(width: 480, height: 64)
    private static let visibleFor: Duration = .milliseconds(1500)

    private let panel: NSPanel
    private let keystroke = Keystroke()
    private var monitors: [Any] = []
    private var hideTask: Task<Void, Never>?

    init() {
        panel = OverlayWindow.make(frame: NSRect(origin: .zero, size: Self.size))
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: KeystrokeView(keystroke: keystroke))
    }

    var isRunning: Bool { !monitors.isEmpty }

    /// The pill's window-server ID, for the recorder's exclusion list.
    var windowNumber: CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    /// Places the pill on the screen under the cursor and starts listening; no-op when running.
    func start() {
        guard !isRunning else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + Self.bottomInset))
        }
        keystroke.text = nil
        panel.orderFrontRegardless()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                // Global monitors deliver on the main thread.
                MainActor.assumeIsolated { self?.show(event) }
            })
        {
            monitors.append(global)
        }
        // Keys typed into QuickTube's own windows never reach the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.show(event) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    /// Removes the monitors and hides the pill; safe to call when not running.
    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        hideTask?.cancel()
        hideTask = nil
        keystroke.text = nil
        panel.orderOut(nil)
    }

    private func show(_ event: NSEvent) {
        guard
            let text = KeyComboFormatter.format(
                modifiers: .init(eventFlags: event.modifierFlags.rawValue), keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers)
        else { return }
        keystroke.text = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.keystroke.text = nil
        }
    }
}

/// The combo on display, nil while the pill is hidden.
@MainActor
@Observable
final class Keystroke {
    var text: String?
}

struct KeystrokeView: View {
    let keystroke: Keystroke

    var body: some View {
        ZStack {
            if let text = keystroke.text {
                Text(text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: keystroke.text)
        .allowsHitTesting(false)
    }
}
