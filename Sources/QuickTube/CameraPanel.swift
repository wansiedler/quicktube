import AVFoundation
import AppKit
import QuickTubeCore

/// A round, always-on-top bubble showing the default camera, mirrored. It is an ordinary window to
/// ScreenCaptureKit, so it is recorded with the screen. Drag it anywhere; it never takes focus.
/// The camera runs (`startCamera`) independently of the bubble being shown, so the bubble can appear
/// with a live picture the moment a recording starts.
@MainActor
final class CameraPanel {
    private let panel: NSPanel
    private let bubble = BubbleView()
    private let camera = CameraSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    /// The last placement, so unrelated settings changes leave a dragged bubble alone.
    private var placement: (size: CGFloat, corner: Corner, area: CGRect)?

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
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

    /// Configures (first time) and starts the camera on the session queue; the camera light turns on.
    func startCamera() {
        camera.start { [weak self] in self?.mirror() }
    }

    /// Stops the camera on the session queue; the camera light goes off.
    func stopCamera() {
        camera.stop()
    }

    /// Orders the bubble in, at `corner` of `area` (AppKit coordinates), or of the visible frame of the
    /// screen under the cursor when `area` is nil. A visible bubble moves only when the size, the corner
    /// or a given `area` changed.
    func show(size: CGFloat, corner: Corner, in area: CGRect?) {
        let visible = panel.isVisible
        if let placement, visible, placement.size == size, placement.corner == corner,
            area == nil || area == placement.area
        {
            return
        }
        guard let target = area ?? Self.screenUnderCursor() else { return }
        place(size: size, corner: corner, in: target)
        if !visible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        placement = nil
    }

    private static func screenUnderCursor() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let underCursor = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return (underCursor ?? NSScreen.main)?.visibleFrame
    }

    private func place(size wanted: CGFloat, corner: Corner, in area: CGRect) {
        let size = CameraLayout.fittedSize(wanted, in: area)
        let origin = CameraLayout.origin(for: corner, size: size, in: area)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        bubble.resize(diameter: size, preview: previewLayer)
        placement = (wanted, corner, area)
    }

    /// The preview connection exists once the input is added; mirror it like a FaceTime preview.
    private func mirror() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

/// Owns the capture session. Configuring, starting and stopping block, so they all run on one serial
/// queue, never on the main thread; `configured` is only touched there.
private final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "QuickTube.camera")
    private var configured = false

    /// `onConfigured` runs on the main actor after the first successful configuration.
    func start(onConfigured: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            if !configured {
                guard configure() else { return }
                configured = true
                Task { @MainActor in onConfigured() }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Adds the default video device; fails (and is retried on the next start) when there is none.
    private func configure() -> Bool {
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
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            return true
        } catch {
            DiagnosticsLog.append("Camera bubble: \(error)")
            return false
        }
    }

    /// The system default camera (FaceTime or Continuity), else the first built-in or external one.
    private static func defaultCamera() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(for: .video) { return device }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified
        ).devices.first
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
