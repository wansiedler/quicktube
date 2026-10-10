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
    private static let comboKeys: [Destination: String] = [
        .youtube: "hotkey.combo", .telegram: "hotkey.telegramCombo",
        .drive: "hotkey.driveCombo", .slack: "hotkey.slackCombo",
    ]
    private static let slots: [Destination: UInt32] = [.youtube: 1, .telegram: 2, .drive: 3, .slack: 4]

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
    private static let qualityKey = "recording.quality"
    var quality: RecordingQuality {
        didSet {
            if let data = try? JSONEncoder().encode(quality) {
                UserDefaults.standard.set(data, forKey: Self.qualityKey)
            }
        }
    }
    private(set) var launchAtLogin = false
    var launchAtLoginMessage: String?
    private(set) var microphoneStatus = Permissions.microphone
    private(set) var screenRecordingStatus = Permissions.screenRecording

    init() {
        let store = KeychainStore()
        let storedQuality =
            UserDefaults.standard.data(forKey: Self.qualityKey)
            .flatMap { try? JSONDecoder().decode(RecordingQuality.self, from: $0) } ?? .default
        self.quality = storedQuality
        // The recorder reads the preset at every start; UserDefaults is the handoff.
        let qualityKey = Self.qualityKey
        let auth = GoogleAuth(store: store)
        self.auth = auth
        let telegram = TelegramUploader(store: store, log: { DiagnosticsLog.append($0) })
        self.telegram = telegram
        let slack = SlackUploader(store: store, log: { DiagnosticsLog.append($0) })
        self.slack = slack
        let notifier = AppNotifier()
        self.notifier = notifier
        self.state = AppState(
            recorder: Recorder(quality: {
                UserDefaults.standard.data(forKey: qualityKey)
                    .flatMap { try? JSONDecoder().decode(RecordingQuality.self, from: $0) } ?? .default
            }),
            uploaders: [
                .youtube: YouTubeUploader(tokens: auth, log: { DiagnosticsLog.append($0) }),
                .telegram: telegram,
                .drive: GoogleDriveUploader(tokens: auth, log: { DiagnosticsLog.append($0) }),
                .slack: slack,
            ],
            notifier: notifier)
        for destination in Destination.allCases {
            let fallback = HotkeyManager.Combo.fallback(for: destination)
            combos[destination] =
                UserDefaults.standard.data(forKey: Self.comboKeys[destination]!)
                .flatMap { try? JSONDecoder().decode(HotkeyManager.Combo.self, from: $0) } ?? fallback
        }
        hotkey.onPress = { [weak self] slot in
            guard let self, let destination = Self.slots.first(where: { $0.value == slot })?.key else {
                return
            }
            Task { await self.state.toggle(destination: destination) }
        }
        for destination in Destination.allCases {
            let combo = combos[destination]!
            if !hotkey.register(combo, slot: Self.slots[destination]!) {
                hotkeyMessage = "\(combo.label) is already in use by another app. Choose another shortcut."
            }
        }
        // A revoked or missing token surfaces during upload; re-read the Keychain so
        // Settings stops showing "Signed in".
        notifier.onFailure = { [weak self] in
            guard let self, self.state.failureKind == .auth else { return }
            self.refreshAuth()
        }
        hud = HUDController(state: state)
        notifier.requestPermission()
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

    func refreshPermissions() {
        microphoneStatus = Permissions.microphone
        screenRecordingStatus = Permissions.screenRecording
    }

    func requestMicrophone() {
        Task {
            microphoneStatus = await Permissions.requestMicrophone()
        }
    }

    func requestScreenRecording() {
        screenRecordingStatus = Permissions.requestScreenRecording()
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
        if hotkey.register(newCombo, slot: slot) {
            combos[destination] = newCombo
            hotkeyMessage = nil
            if let data = try? JSONEncoder().encode(newCombo) {
                UserDefaults.standard.set(data, forKey: Self.comboKeys[destination]!)
            }
        } else {
            hotkey.register(previous, slot: slot)
            hotkeyMessage = "\(newCombo.label) is already in use by another app. Kept \(previous.label)."
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(
            at: Recorder.defaultDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.defaultDirectory)
    }
}
