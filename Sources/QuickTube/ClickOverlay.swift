import AppKit
import Observation
import SwiftUI

/// Draws a fading ring at every mouse-down, on transparent click-through windows, one per screen.
/// Global `NSEvent` monitors need no permission; they miss clicks into QuickTube's own windows, which a
/// local monitor covers. `start` adds the monitors and orders the windows in (so they are on screen,
/// and excludable, before capture starts); `stop` removes both.
@MainActor
final class ClickOverlay {
    private var windows: [(panel: NSPanel, rings: ClickRings)] = []
    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    /// The ring windows' window-server IDs, for the recorder's exclusion list.
    var windowNumbers: [CGWindowID] {
        windows.compactMap { $0.panel.windowNumber > 0 ? CGWindowID($0.panel.windowNumber) : nil }
    }

    /// Covers the current screens and starts listening; does nothing when already running.
    func start() {
        guard !isRunning else { return }
        windows = NSScreen.screens.map { screen in
            let rings = ClickRings()
            let panel = OverlayWindow.make(frame: screen.frame)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            panel.contentView = NSHostingView(rootView: ClickRingsView(rings: rings))
            panel.orderFrontRegardless()
            return (panel, rings)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: { [weak self] _ in
                // Global monitors deliver on the main thread.
                MainActor.assumeIsolated { self?.click(at: NSEvent.mouseLocation) }
            })
        {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.click(at: NSEvent.mouseLocation) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    /// Removes the monitors and the windows; safe to call when not running.
    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        for window in windows {
            window.panel.orderOut(nil)
            window.panel.close()
        }
        windows = []
    }

    /// `point` is in AppKit global coordinates (bottom-left origin).
    private func click(at point: NSPoint) {
        guard let window = windows.first(where: { NSMouseInRect(point, $0.panel.frame, false) }) else {
            return
        }
        let frame = window.panel.frame
        // SwiftUI's origin is the top-left of the window.
        window.rings.add(CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }
}

/// Shared setup for the overlay windows: borderless, transparent, never focused, ignoring the mouse,
/// on every Space. Not deferred, so the window number exists as soon as it is created.
@MainActor
enum OverlayWindow {
    static func make(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// The rings currently fading on one screen.
@MainActor
@Observable
final class ClickRings {
    struct Ring: Identifiable {
        let id = UUID()
        let center: CGPoint
        let date: Date
    }

    static let lifetime: TimeInterval = 0.4
    private(set) var rings: [Ring] = []

    func add(_ center: CGPoint) {
        let ring = Ring(center: center, date: Date())
        rings.append(ring)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            self?.rings.removeAll { $0.id == ring.id }
        }
    }
}

struct ClickRingsView: View {
    let rings: ClickRings
    private static let diameter: CGFloat = 44

    var body: some View {
        // Animates only while a ring is fading.
        TimelineView(.animation(paused: rings.rings.isEmpty)) { context in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(rings.rings) { ring in
                    let progress = min(
                        1, max(0, context.date.timeIntervalSince(ring.date) / ClickRings.lifetime))
                    Circle()
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .background(Circle().fill(Color.yellow.opacity(0.2)))
                        .frame(width: Self.diameter, height: Self.diameter)
                        .scaleEffect(0.6 + 0.6 * progress)
                        .opacity(1 - progress)
                        .position(ring.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
