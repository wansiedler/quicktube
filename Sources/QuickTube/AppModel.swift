import AppKit
import Observation
import QuickTubeCore

/// Wires Core to the UI and owns the user-facing settings.
@MainActor
@Observable
final class AppModel {
    let auth: GoogleAuth
    let telegram: TelegramUploader
    let state: AppState
    private let hotkey = HotkeyManager()
    private let notifier: AppNotifier
    private var hud: HUDController?
    private let selectionOverlay = SelectionOverlay()
    private let camera = CameraPanel()
    private let clickOverlay = ClickOverlay()
    private let keystrokeOverlay = KeystrokeOverlay()
    /// The windows the recorder leaves out; filled in once the HUD exists.
    private let exclusions = WindowExclusions()
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    private static let comboKeys: [Destination: String] = [
        .youtube: "hotkey.combo", .telegram: "hotkey.telegramCombo",
        .drive: "hotkey.driveCombo", .slack: "hotkey.slackCombo", .gif: "hotkey.gifCombo",
    ]
    /// Slot 5 is pause; the GIF hotkey (slot 6) is registered only while `gifEnabled` is on.
    private static let slots: [Destination: UInt32] = [
        .youtube: 1, .telegram: 2, .drive: 3, .slack: 4, .gif: 6,
    ]
    /// Pause/resume; registered only while `pauseEnabled` is on.
    private static let pauseSlot: UInt32 = 5
    static let pauseCombo = HotkeyManager.Combo.pauseDefault

    private(set) var combos: [Destination: HotkeyManager.Combo] = [:]
    var hotkeyMessage: String?
    var telegramToken = ""
    var telegramChat = ""
    var telegramConfigured = false
    var telegramMessage: String?
    let slack: SlackUploader
    var slackToken = ""
    var slackChannel = ""
    var slackConfigured = false
    var slackMessage: String?
    var clientID = ""
    var clientSecret = ""
    var signedIn = false
    var signingIn = false
    var authMessage: String?
    private var signInTask: Task<Void, Never>?
    let settingsStore: SettingsStore
    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }
    private(set) var launchAtLogin = false
    var launchAtLoginMessage: String?
    private(set) var microphoneStatus = Permissions.microphone
    private(set) var screenRecordingStatus = Permissions.screenRecording
    private(set) var cameraStatus = Permissions.camera
    private(set) var inputMonitoringStatus = Permissions.inputMonitoring

    /// The frontmost app and the screen under the cursor, read when a recording starts.
    private static func currentTitleContext() -> TitleContext {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        return TitleContext(
            app: NSWorkspace.shared.frontmostApplication?.localizedName,
            display: screen?.localizedName)
    }

    init() {
        let store = KeychainStore()
        self.settingsStore = SettingsStore()
        let auth = GoogleAuth(store: store)
        self.auth = auth
        let telegram = TelegramUploader(
            store: store,
            limitBytes: { AppSettings.load(from: .standard).telegramLimitBytes },
            compressToFit: { AppSettings.load(from: .standard).telegramCompressToFit },
            allowDownscale: { AppSettings.load(from: .standard).telegramAllowDownscale },
            log: { DiagnosticsLog.append($0) })
        self.telegram = telegram
        let slack = SlackUploader(store: store, log: { DiagnosticsLog.append($0) })
        self.slack = slack
        let notifier = AppNotifier()
        self.notifier = notifier
        let exclusions = exclusions
        self.state = AppState(
            recorder: Recorder(
                options: {
                    // The store persists every change to UserDefaults; read it back at each start.
                    let settings = AppSettings.load(from: .standard)
                    return RecorderOptions(
                        quality: settings.quality, systemAudio: settings.systemAudioEnabled,
                        microphone: settings.microphoneEnabled)
                }, excludedWindows: { exclusions.windows() }, log: { DiagnosticsLog.append($0) }),
            uploaders: [
                .youtube: YouTubeUploader(tokens: auth, log: { DiagnosticsLog.append($0) }),
                .telegram: telegram,
                .drive: GoogleDriveUploader(tokens: auth, log: { DiagnosticsLog.append($0) }),
                .slack: slack,
                .gif: GIFUploader(
                    options: {
                        let settings = AppSettings.load(from: .standard)
                        return GIFOptions(
                            fps: settings.gifFPS, maxWidth: settings.gifMaxWidth,
                            maxSeconds: settings.gifMaxSeconds)
                    }, log: { DiagnosticsLog.append($0) }),
            ],
            notifier: notifier,
            trim: {
                let settings = AppSettings.load(from: .standard)
                return TrimSettings(head: settings.trimHeadSeconds, tail: settings.trimTailSeconds)
            },
            picker: selectionOverlay,
            captureMode: { AppSettings.load(from: .standard).captureMode },
            titleProvider: { MainActor.assumeIsolated { Self.currentTitleContext() } },
            titleTemplate: { AppSettings.load(from: .standard).titleTemplate },
            log: { DiagnosticsLog.append($0) },
            history: Self.loadHistory(),
            historyEnabled: { AppSettings.load(from: .standard).historyEnabled },
            onHistoryChange: { Self.saveHistory($0) },
            afterUpload: { file in
                guard AppSettings.load(from: .standard).deleteAfterUpload else { return }
                try RecordingCleanup(files: DefaultRecordingFiles()).trashAfterUpload(file)
            })
        for destination in Destination.allCases {
            let fallback = HotkeyManager.Combo.fallback(for: destination)
            combos[destination] =
                UserDefaults.standard.data(forKey: Self.comboKeys[destination]!)
                .flatMap { try? JSONDecoder().decode(HotkeyManager.Combo.self, from: $0) } ?? fallback
        }
        hotkey.onPress = { [weak self] slot in
            guard let self else { return }
            if slot == Self.pauseSlot {
                Task { await self.state.togglePause() }
                return
            }
            guard let destination = Self.slots.first(where: { $0.value == slot })?.key else { return }
            // A recording hotkey while the selection overlay is up cancels it, rather than being ignored.
            if self.selectionOverlay.isPicking {
                self.selectionOverlay.cancel()
                return
            }
            Task { await self.state.toggle(destination: destination) }
        }
        for destination in Destination.allCases where destination != .gif {
            let combo = combos[destination]!
            if !hotkey.register(combo, slot: Self.slots[destination]!) {
                hotkeyMessage = "\(combo.label) is already in use by another app. Choose another shortcut."
            }
        }
        updatePauseHotkey()
        updateGIFHotkey()
        // A revoked or missing token surfaces during upload; re-read the Keychain so
        // Settings stops showing "Signed in".
        notifier.onFailure = { [weak self] in
            guard let self, self.state.failureKind == .auth else { return }
            self.refreshAuth()
        }
        let hud = HUDController(state: state)
        self.hud = hud
        // The HUD and the selection overlay stay out of recordings; the camera bubble is recorded; the
        // click and keystroke overlays are recorded unless "Show overlays in recording" is off.
        exclusions.windows = { [weak hud, selectionOverlay, clickOverlay, keystrokeOverlay, settingsStore] in
            var windows = [hud?.windowNumber, selectionOverlay.windowNumber].compactMap { $0 }
            if !settingsStore.settings.overlaysInRecording {
                windows += clickOverlay.windowNumbers
                windows += [keystrokeOverlay.windowNumber].compactMap { $0 }
            }
            return windows
        }
        // Show the bubble and the overlay windows before the recorder starts, so the bubble is in the
        // first frame and the overlays are on screen (and excludable) when the capture filter is built.
        state.onRecordingWillStart = { [weak self] _ in
            self?.updateCamera()
            self?.updateOverlays()
        }
        observeCamera()
        observeOverlays()
        // Grants changed in System Settings take effect when QuickTube is next activated.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        notifier.requestPermission()
        trashOldRecordings()
        refreshAuth()
        refreshTelegram()
        refreshSlack()
        // Ask for the recording grants now, so the first hotkey press records instead of prompting.
        if Bundle.main.bundleIdentifier != nil {
            Task {
                await Permissions.requestMissing()
                refreshPermissions()
            }
        }
    }

    /// At launch: trashes recordings older than the configured number of days, off the main thread.
    private func trashOldRecordings() {
        let days = settings.deleteOlderThanDays
        guard days > 0 else { return }
        Task.detached {
            do {
                let trashed = try RecordingCleanup(files: DefaultRecordingFiles())
                    .trashOlder(than: days, in: Recorder.defaultDirectory)
                if !trashed.isEmpty { DiagnosticsLog.append("Trashed \(trashed.count) old recordings") }
            } catch {
                DiagnosticsLog.append("Trashing old recordings failed: \(error)")
            }
        }
    }

    private static let historyKey = "history.v2"

    /// Bad or missing data gives an empty history.
    private static func loadHistory() -> [HistoryItem] {
        UserDefaults.standard.data(forKey: historyKey)
            .flatMap { try? JSONDecoder().decode([HistoryItem].self, from: $0) } ?? []
    }

    private static func saveHistory(_ items: [HistoryItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func copyToPasteboard(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    func refreshPermissions() {
        microphoneStatus = Permissions.microphone
        screenRecordingStatus = Permissions.screenRecording
        cameraStatus = Permissions.camera
        inputMonitoringStatus = Permissions.inputMonitoring
    }

    /// Only from the Settings button; never at launch.
    func requestInputMonitoring() {
        inputMonitoringStatus = Permissions.requestInputMonitoring()
    }

    /// Re-arms after every change, like `observeCamera`.
    private func observeOverlays() {
        withObservationTracking {
            updateOverlays()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlays() }
        }
    }

    /// Each enabled overlay runs while a recording starts, runs or is paused, and stops otherwise; the
    /// keystroke overlay also needs the Input Monitoring grant. Start and stop are idempotent.
    private func updateOverlays() {
        let settings = settings
        let recording: Bool
        switch state.phase {
        case .recording, .paused: recording = true
        default: recording = state.isStarting
        }
        if recording && settings.clickHighlightEnabled {
            clickOverlay.start()
        } else {
            clickOverlay.stop()
        }
        if recording && settings.keystrokeOverlayEnabled && inputMonitoringStatus == .granted {
            keystrokeOverlay.start()
        } else {
            keystrokeOverlay.stop()
        }
    }

    func requestCamera() {
        Task {
            cameraStatus = await Permissions.requestCamera()
        }
    }

    /// Turns the camera bubble on or off; the first time on asks for the camera grant.
    func setCameraEnabled(_ enabled: Bool) {
        settings.cameraEnabled = enabled
        if enabled, Permissions.camera == .notDetermined {
            requestCamera()
        }
    }

    /// Re-arms after every change, like `HUDController`: recording phase and settings drive the bubble.
    private func observeCamera() {
        withObservationTracking {
            updateCamera()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeCamera() }
        }
    }

    /// With the bubble enabled and granted, it shows while a recording starts, runs or is paused, placed
    /// in the captured area, and always (on the screen under the cursor) when "always on" is set too.
    /// The camera runs only while the bubble shows. Reads only observable state, so a grant or settings
    /// change re-runs it.
    private func updateCamera() {
        let settings = settings
        let enabled = settings.cameraEnabled && cameraStatus == .granted
        let recording: Bool
        switch state.phase {
        case .recording, .paused: recording = true
        default: recording = state.isStarting
        }
        // Window captures can never contain the bubble, so it is only worth showing on its own ("Always on").
        let windowCapture: Bool
        if case .window = state.recordingTarget { windowCapture = true } else { windowCapture = false }
        guard enabled, settings.cameraAlwaysOn || (recording && !windowCapture) else {
            camera.hide()
            return
        }
        camera.show(
            size: settings.cameraSize.points, corner: settings.cameraCorner,
            in: recording ? Self.cameraArea(for: state.recordingTarget) : nil)
    }

    /// Where the bubble goes for `target`, in AppKit coordinates: the display's visible frame, or the
    /// region itself. Nil (the screen under the cursor) for window captures, which cannot contain it.
    private static func cameraArea(for target: CaptureTarget?) -> CGRect? {
        func screen(_ id: CGDirectDisplayID) -> NSScreen? {
            NSScreen.screens.first { $0.displayID == id }
        }
        switch target {
        case .display(let id): return screen(id)?.visibleFrame
        case .region(let id, let rect):
            return screen(id).map { CameraLayout.appKitRect(region: rect, onScreen: $0.frame) }
        case .window, nil: return nil
        }
    }

    func requestMicrophone() {
        Task {
            microphoneStatus = await Permissions.requestMicrophone()
        }
    }

    func requestScreenRecording() {
        screenRecordingStatus = Permissions.requestScreenRecording()
    }

    /// Turns pause/resume (menu item and hotkey) on or off.
    func setPauseEnabled(_ enabled: Bool) {
        settings.pauseEnabled = enabled
        updatePauseHotkey()
    }

    private func updatePauseHotkey() {
        guard settings.pauseEnabled else {
            hotkey.remove(slot: Self.pauseSlot)
            return
        }
        if combos.values.contains(Self.pauseCombo) {
            hotkeyMessage =
                "\(Self.pauseCombo.label) is taken by a destination shortcut; pause has no hotkey."
        } else if !hotkey.register(Self.pauseCombo, slot: Self.pauseSlot) {
            hotkeyMessage = "\(Self.pauseCombo.label) is already in use by another app; pause has no hotkey."
        }
    }

    /// Turns the GIF destination (menu item and hotkey) on or off.
    func setGIFEnabled(_ enabled: Bool) {
        settings.gifEnabled = enabled
        updateGIFHotkey()
    }

    private static let gifConflictSuffix = "; GIF has no hotkey."

    private func updateGIFHotkey() {
        let slot = Self.slots[.gif]!
        guard settings.gifEnabled else {
            hotkey.remove(slot: slot)
            if hotkeyMessage?.hasSuffix(Self.gifConflictSuffix) == true { hotkeyMessage = nil }
            return
        }
        let combo = combo(for: .gif)
        if !hotkey.register(combo, slot: slot) {
            hotkeyMessage = "\(combo.label) is already in use by another app\(Self.gifConflictSuffix)"
        }
    }

    /// The destinations offered in the menu and the status line: GIF only while it is enabled.
    var visibleDestinations: [Destination] {
        Destination.allCases.filter { $0 != .gif || settings.gifEnabled }
    }

    func combo(for destination: Destination) -> HotkeyManager.Combo {
        combos[destination] ?? .fallback(for: destination)
    }

    /// Registers `newCombo` for `destination` and persists it; on failure keeps the previous shortcut.
    func setCombo(_ newCombo: HotkeyManager.Combo, for destination: Destination) {
        let previous = combo(for: destination)
        let slot = Self.slots[destination]!
        if let other = combos.first(where: { $0.key != destination && $0.value == newCombo }) {
            hotkeyMessage = "\(newCombo.label) is already the \(other.key.label) shortcut."
            return
        }
        if settings.pauseEnabled, newCombo == Self.pauseCombo {
            hotkeyMessage = "\(newCombo.label) is the pause shortcut."
            return
        }
        // A disabled GIF shortcut is only stored; it is registered when GIF is turned on.
        if destination == .gif, !settings.gifEnabled {
            store(newCombo, for: destination)
        } else if hotkey.register(newCombo, slot: slot) {
            store(newCombo, for: destination)
        } else {
            hotkey.register(previous, slot: slot)
            hotkeyMessage = "\(newCombo.label) is already in use by another app. Kept \(previous.label)."
        }
    }

    private func store(_ combo: HotkeyManager.Combo, for destination: Destination) {
        combos[destination] = combo
        hotkeyMessage = nil
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.comboKeys[destination]!)
        }
    }

    func refreshSlack() {
        Task {
            do {
                if let configuration = try await slack.configuration() {
                    slackToken = configuration.token
                    slackChannel = configuration.channel
                    slackConfigured = true
                } else {
                    slackConfigured = false
                }
            } catch {
                slackMessage = "Keychain error: \(error)"
            }
        }
    }

    func saveSlack() {
        let configuration = SlackConfiguration(
            token: slackToken.trimmingCharacters(in: .whitespacesAndNewlines),
            channel: slackChannel.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                if configuration.token.isEmpty || configuration.channel.isEmpty {
                    try await slack.clearConfiguration()
                    slackConfigured = false
                    slackMessage = "Slack cleared."
                } else {
                    try await slack.setConfiguration(configuration)
                    slackConfigured = true
                    slackMessage = "Slack saved."
                }
            } catch {
                slackMessage = "Could not save to Keychain: \(error)"
            }
        }
    }

    func refreshTelegram() {
        Task {
            do {
                if let configuration = try await telegram.configuration() {
                    telegramToken = configuration.botToken
                    telegramChat = configuration.chat
                    telegramConfigured = true
                } else {
                    telegramConfigured = false
                }
            } catch {
                telegramMessage = "Keychain error: \(error)"
            }
        }
    }

    func saveTelegram() {
        let configuration = TelegramConfiguration(
            botToken: telegramToken.trimmingCharacters(in: .whitespacesAndNewlines),
            chat: telegramChat.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                if configuration.botToken.isEmpty || configuration.chat.isEmpty {
                    try await telegram.clearConfiguration()
                    telegramConfigured = false
                    telegramMessage = "Telegram cleared."
                } else {
                    try await telegram.setConfiguration(configuration)
                    telegramConfigured = true
                    telegramMessage = "Telegram saved."
                }
            } catch {
                telegramMessage = "Could not save to Keychain: \(error)"
            }
        }
    }

    /// Re-reads the login-item state; the user may have changed it in System Settings.
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginMessage = LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func suspendHotkey() {
        hotkey.suspend()
    }

    func resumeHotkey() {
        hotkey.resume()
    }

    func refreshAuth() {
        Task {
            do {
                signedIn = try await auth.isSignedIn()
                if let client = try await auth.client() {
                    clientID = client.id
                    clientSecret = client.secret
                }
            } catch {
                authMessage = "Keychain error: \(error)"
            }
        }
    }

    private var enteredClient: OAuthClient {
        OAuthClient(
            id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func saveClient() {
        let client = enteredClient
        Task {
            do {
                try await auth.setClient(client)
                authMessage = "Client saved."
            } catch {
                authMessage = "Could not save to Keychain: \(error)"
            }
        }
    }

    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        authMessage = "Waiting for the browser…"
        let client = enteredClient
        signInTask = Task {
            defer {
                signingIn = false
                signInTask = nil
            }
            do {
                // Sign in with what is in the fields, even if "Save client" was never pressed.
                guard !client.id.isEmpty, !client.secret.isEmpty else { throw AuthError.missingClient }
                try await auth.setClient(client)
                try await auth.signIn { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                signedIn = true
                authMessage = "Signed in."
            } catch {
                authMessage = AppState.message(for: error, stage: .signIn)
            }
        }
    }

    /// Stops a pending sign-in; the flow ends with "Sign-in cancelled."
    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() {
        Task {
            do {
                try await auth.signOut()
                signedIn = false
                authMessage = nil
            } catch {
                authMessage = "Keychain error: \(error)"
            }
        }
    }

    func copyLastLink() {
        guard let link = state.lastLink else { return }
        copyToPasteboard(link)
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(
            at: Recorder.defaultDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.defaultDirectory)
    }
}

/// A late-bound list of window IDs, readable from the recorder's closure before the HUD exists.
@MainActor
private final class WindowExclusions {
    var windows: () -> [CGWindowID] = { [] }
}
