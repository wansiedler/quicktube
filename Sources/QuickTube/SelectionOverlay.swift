import AppKit
import QuickTubeCore
import ScreenCaptureKit

/// Full-screen chooser on the display under the cursor: drag an area, or click a highlighted window.
/// Esc, a right click, a QuickTube recording hotkey or a display change cancels. The overlay is a
/// non-activating panel, so it takes key input without activating QuickTube. The recorder excludes it
/// by `windowNumber`, so the overlay never shows up in a recording.
@MainActor
final class SelectionOverlay: CaptureTargetPicker {
    private var window: OverlayPanel?
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?
    /// True from the start of a pick until it returns, including while the window list loads.
    private(set) var isPicking = false
    /// Set by `cancel()` while the window list loads, before the overlay exists.
    private var cancelled = false
    private var screenObserver: NSObjectProtocol?

    /// The overlay's window-server ID while it is up, for the recorder's exclusion list.
    var windowNumber: CGWindowID? {
        guard let window, window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
    }

    /// Ends a pick in flight as cancelled; does nothing otherwise.
    func cancel() {
        guard isPicking else { return }
        cancelled = true
        finish(nil)
    }

    func pick(mode: CaptureMode) async -> CaptureTarget? {
        guard !isPicking else { return nil }
        isPicking = true
        cancelled = false
        defer { isPicking = false }
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main,
            let displayID = screen.displayID
        else { return nil }

        var candidates: [WindowCandidate] = []
        if mode == .selectWindow {
            do {
                candidates = try await Self.windowCandidates()
            } catch {
                DiagnosticsLog.append("Window list unavailable: \(error)")
                // Without the Screen Recording grant, hand the display to the recorder so it reports the
                // permission error. With it, never widen a window pick to the whole display: cancel.
                return CGPreflightScreenCaptureAccess() ? nil : .display(displayID)
            }
        }
        guard !cancelled else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            // A display added, removed or rearranged invalidates the overlay's geometry.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(nil) }
            }
            let view = SelectionView(
                mode: mode, displayID: displayID, screen: screen, candidates: candidates,
                finish: { [weak self] target in self?.finish(target) })
            let window = OverlayPanel(screen: screen, view: view)
            self.window = window
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            view.refreshHover(at: window.mouseLocationOutsideOfEventStream)
        }
    }

    /// Resumes the pending pick exactly once and removes the overlay.
    private func finish(_ target: CaptureTarget?) {
        guard let continuation else { return }
        self.continuation = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let closing = window
        window = nil
        closing?.orderOut(nil)
        // `finish` usually runs inside the panel's own event handler; release it after that returns.
        DispatchQueue.main.async { withExtendedLifetime(closing) {} }
        NSCursor.arrow.set()
        continuation.resume(returning: target)
    }

    // MARK: - Window list

    /// A window that can be picked; frame in global CoreGraphics coordinates (origin top-left of the main display).
    struct WindowCandidate: Sendable {
        let id: CGWindowID
        let frame: CGRect
        let title: String
    }

    /// Lets the non-Sendable SDK result leave the nonisolated helper.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    private nonisolated static func shareableContent() async throws -> Unchecked<SCShareableContent> {
        Unchecked(
            value: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
    }

    /// On-screen, visible (alpha > 0), normal-layer, non-QuickTube windows, frontmost first.
    private static func windowCandidates() async throws -> [WindowCandidate] {
        let content = try await shareableContent().value
        let ownBundle = Bundle.main.bundleIdentifier
        // SCShareableContent has no z-order; the CG window list is front to back.
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        var transparent: Set<CGWindowID> = []
        for (index, entry) in info.enumerated() {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            order[number.uint32Value] = index
            if let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 {
                transparent.insert(number.uint32Value)
            }
        }
        return content.windows
            .filter { window in
                window.windowLayer == 0 && window.frame.width > 0 && window.frame.height > 0
                    && window.owningApplication?.bundleIdentifier != ownBundle
                    && !transparent.contains(window.windowID)
            }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
            .map { window in
                let app = window.owningApplication?.applicationName ?? ""
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
                return WindowCandidate(
                    id: window.windowID, frame: window.frame,
                    title: [app, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
            }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// A non-activating panel that still becomes key, so Esc and mouse moves reach it while the
/// frontmost app keeps focus.
private final class OverlayPanel: NSPanel {
    init(screen: NSScreen, view: NSView) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The chooser never belongs in anyone's capture.
        sharingType = .none
        contentView = view
    }

    override var canBecomeKey: Bool { true }
}

/// Draws the dimmed backdrop, the selection or highlighted window, and its label; handles the input.
private final class SelectionView: NSView {
    private let mode: CaptureMode
    private let displayID: CGDirectDisplayID
    private let screenFrame: CGRect
    private let backingScale: CGFloat
    /// Height of the primary screen, for flipping CoreGraphics global coordinates to AppKit ones.
    private let primaryHeight: CGFloat
    private let candidates: [SelectionOverlay.WindowCandidate]
    private let finish: (CaptureTarget?) -> Void

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hovered: SelectionOverlay.WindowCandidate?

    init(
        mode: CaptureMode, displayID: CGDirectDisplayID, screen: NSScreen,
        candidates: [SelectionOverlay.WindowCandidate], finish: @escaping (CaptureTarget?) -> Void
    ) {
        self.mode = mode
        self.displayID = displayID
        self.screenFrame = screen.frame
        self.backingScale = screen.backingScaleFactor
        self.primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        self.candidates = candidates
        self.finish = finish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .selectArea ? .crosshair : .pointingHand)
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    override func mouseMoved(with event: NSEvent) {
        (mode == .selectArea ? NSCursor.crosshair : NSCursor.pointingHand).set()
        refreshHover(at: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .selectArea:
            dragStart = convert(event.locationInWindow, from: nil)
            dragCurrent = dragStart
            needsDisplay = true
        case .selectWindow:
            refreshHover(at: event.locationInWindow)
            if let hovered { finish(.window(hovered.id)) }
        case .displayUnderCursor:
            finish(.display(displayID))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .selectArea, dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .selectArea, dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        defer {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
        // Too small (a stray click) keeps the overlay open for another try.
        guard let selection,
            let target = CaptureTarget.region(
                display: displayID, selection: selection, screenSize: bounds.size)
        else { return }
        finish(target)
    }

    /// Highlights the frontmost candidate under `windowPoint` (window coordinates).
    func refreshHover(at windowPoint: NSPoint) {
        guard mode == .selectWindow else { return }
        let local = convert(windowPoint, from: nil)
        let global = CGPoint(
            x: screenFrame.minX + local.x, y: primaryHeight - (screenFrame.minY + local.y))
        let hit = candidates.first { $0.frame.contains(global) }
        if hit?.id != hovered?.id {
            hovered = hit
            needsDisplay = true
        }
    }

    // MARK: Drawing

    private var selection: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
    }

    /// A window frame in global CoreGraphics coordinates, in this view's coordinates.
    private func local(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - screenFrame.minX, y: primaryHeight - frame.maxY - screenFrame.minY,
            width: frame.width, height: frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let highlight: CGRect?
        let label: String?
        switch mode {
        case .selectArea:
            highlight = selection
            label = selection.map {
                "\(Int(($0.width * backingScale).rounded())) × \(Int(($0.height * backingScale).rounded()))"
            }
        case .selectWindow:
            highlight = hovered.map { local($0.frame) }
            label = hovered.map { $0.title.isEmpty ? "Window" : $0.title }
        case .displayUnderCursor:
            highlight = nil
            label = nil
        }
        if let highlight {
            NSColor.clear.setFill()
            highlight.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        drawLabel(
            label
                ?? (mode == .selectArea
                    ? "Drag to select an area · Esc to cancel" : "Click a window · Esc to cancel"),
            near: highlight)
    }

    private func drawLabel(_ text: String, near rect: CGRect?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = CGSize(width: 10, height: 5)
        let box = CGSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        var origin: CGPoint
        if let rect {
            // Below the selection's bottom-left corner, else inside it at the top.
            origin = CGPoint(x: rect.minX, y: rect.minY - box.height - 6)
            if origin.y < 4 { origin.y = rect.maxY - box.height - 6 }
        } else {
            origin = CGPoint(x: bounds.midX - box.width / 2, y: bounds.midY - box.height / 2)
        }
        origin.x = min(max(origin.x, 4), bounds.maxX - box.width - 4)
        origin.y = min(max(origin.y, 4), bounds.maxY - box.height - 4)
        let background = NSBezierPath(
            roundedRect: CGRect(origin: origin, size: box), xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        background.fill()
        string.draw(at: CGPoint(x: origin.x + padding.width, y: origin.y + padding.height))
    }
}
