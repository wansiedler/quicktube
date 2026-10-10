import AVFoundation
import AppKit
import QuickTubeCore

/// A round, always-on-top bubble showing the default camera, mirrored. It is an ordinary window to
/// ScreenCaptureKit, so it is recorded with the screen. Drag it anywhere; it never takes focus.
@MainActor
final class CameraPanel {
    private let panel: NSPanel
    private let bubble = BubbleView()
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    /// Starting and stopping a capture session blocks; never do it on the main thread.
    private let sessionQueue = DispatchQueue(label: "QuickTube.camera")
    private var configured = false
    /// Size and corner of the last placement, so unrelated settings changes leave a dragged bubble alone.
    private var placement: (size: CGFloat, corner: Corner)?

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A window shadow would follow the square frame while the video loads.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        bubble.layer?.addSublayer(previewLayer)
        panel.contentView = bubble
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the bubble (starting the camera) or, if it is up, moves it when `size` or `corner` changed.
    /// Placed on the screen under the cursor. Returns false when there is no camera.
    @discardableResult
    func show(size: CGFloat, corner: Corner) -> Bool {
        guard configureIfNeeded() else { return false }
        let alreadyVisible = panel.isVisible
        if !alreadyVisible || placement?.size != size || placement?.corner != corner {
            place(size: size, corner: corner)
        }
        guard !alreadyVisible else { return true }
        panel.orderFrontRegardless()
        let session = Unchecked(value: session)
        sessionQueue.async {
            if !session.value.isRunning { session.value.startRunning() }
        }
        return true
    }

    /// Hides the bubble and stops the camera (its light goes off).
    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        placement = nil
        let session = Unchecked(value: session)
        sessionQueue.async {
            if session.value.isRunning { session.value.stopRunning() }
        }
    }

    private func place(size: CGFloat, corner: Corner) {
        let mouse = NSEvent.mouseLocation
        let underCursor = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        guard let screen = underCursor ?? NSScreen.main else { return }
        let origin = CameraLayout.origin(for: corner, size: size, in: screen.visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        bubble.resize(diameter: size, preview: previewLayer)
        placement = (size, corner)
    }

    /// Adds the default video device once; fails (and retries next time) when there is none.
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = Self.defaultCamera() else {
            DiagnosticsLog.append("Camera bubble: no camera found")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else {
                DiagnosticsLog.append("Camera bubble: cannot use \(device.localizedName)")
                return false
            }
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.high) ? .high : session.sessionPreset
        } catch {
            DiagnosticsLog.append("Camera bubble: \(error)")
            return false
        }
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        configured = true
        return true
    }

    /// The system default camera (FaceTime or Continuity), else the first built-in or external one.
    private static func defaultCamera() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(for: .video) { return device }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.first
    }

    /// Lets the session cross to the session queue; it is only started and stopped there.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }
}

/// Round, white-rimmed container for the preview; a drag anywhere on it moves the panel.
private final class BubbleView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 3
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    func resize(diameter: CGFloat, preview: CALayer) {
        frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = diameter / 2
        // The layer border is composited above sublayers, so the rim stays on top of the video.
        preview.frame = bounds
        CATransaction.commit()
    }
}
