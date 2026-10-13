import AppKit
import Carbon
import Observation
import QuickTubeCore
import SwiftUI

/// A pill at the bottom centre of the screen, just above the HUD, showing the last key combo for
/// 1.5 s. Keys are read through a listen-only `CGEvent` tap, which is what Input Monitoring grants
/// (a global `NSEvent` key monitor would need Accessibility instead); the caller starts it only
/// when granted.
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
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hideTask: Task<Void, Never>?
    /// Settings → Overlays "Show only shortcuts"; read per key press.
    var shortcutsOnly: () -> Bool = { true }

    init() {
        panel = OverlayWindow.make(frame: NSRect(origin: .zero, size: Self.size))
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: KeystrokeView(keystroke: keystroke))
    }

    var isRunning: Bool { tap != nil || !monitors.isEmpty }

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
        installTap()
        // Keys typed into QuickTube's own windows never reach the tap once the app handles them.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.show(KeyPress(event)) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    /// A session-wide, listen-only tap on key presses, serviced on the main run loop so the callback
    /// is on the main thread. Fails silently (logged by the caller's status) without the grant.
    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: keystrokeTapCallback, userInfo: refcon)
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    /// What the pill needs from a key press; plain values, so they can cross into the main actor.
    struct KeyPress: Sendable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let characters: String?

        init(_ event: NSEvent) {
            keyCode = event.keyCode
            modifierFlags = event.modifierFlags.rawValue
            characters = event.charactersIgnoringModifiers
        }
    }

    /// Called by the tap on the main thread; a disabled tap (timeout) is switched back on.
    fileprivate func handleTap(type: CGEventType, key: KeyPress?) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if let key { show(key) }
        default:
            break
        }
    }

    /// Removes the tap and monitors and hides the pill; safe to call when not running.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        hideTask?.cancel()
        hideTask = nil
        keystroke.text = nil
        panel.orderOut(nil)
    }

    private func show(_ key: KeyPress) {
        // A password field (or a terminal with Secure Keyboard Entry) is active: show nothing.
        guard !IsSecureEventInputEnabled() else { return }
        let modifiers = KeyComboFormatter.Modifiers(eventFlags: key.modifierFlags)
        guard
            KeyComboFormatter.shouldShow(
                modifiers: modifiers, keyCode: key.keyCode, shortcutsOnly: shortcutsOnly()),
            let text = KeyComboFormatter.format(
                modifiers: modifiers, keyCode: key.keyCode, characters: key.characters)
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

/// C entry point for the tap; `refcon` is the unretained overlay, and the tap's run-loop source
/// lives on the main run loop, so this runs on the main thread.
private func keystrokeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let overlay = Unmanaged<KeystrokeOverlay>.fromOpaque(refcon).takeUnretainedValue()
        // Converted here, outside the isolated closure, so no CGEvent crosses into the main actor.
        let key = type == .keyDown ? NSEvent(cgEvent: event).map(KeystrokeOverlay.KeyPress.init) : nil
        MainActor.assumeIsolated { overlay.handleTap(type: type, key: key) }
    }
    return Unmanaged.passUnretained(event)
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
