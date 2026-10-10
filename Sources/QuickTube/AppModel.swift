import AppKit
import Observation
import QuickTubeCore

/// Wires Core to the UI and owns the user-facing settings.
@MainActor
@Observable
final class AppModel {
    let auth: GoogleAuth
    let state: AppState
    private let hotkey = HotkeyManager()
    private let notifier: AppNotifier
    private static let comboKey = "hotkey.combo"

    private(set) var combo: HotkeyManager.Combo
    var hotkeyMessage: String?
    var clientID = ""
    var clientSecret = ""
    var signedIn = false
    var signingIn = false
    var authMessage: String?
    private var signInTask: Task<Void, Never>?
    private(set) var launchAtLogin = false
    var launchAtLoginMessage: String?

    init() {
        let auth = GoogleAuth(store: KeychainStore())
        self.auth = auth
        let notifier = AppNotifier()
        self.notifier = notifier
        self.state = AppState(
            recorder: Recorder(),
            uploader: YouTubeUploader(tokens: auth),
            notifier: notifier)
        self.combo =
            UserDefaults.standard.data(forKey: Self.comboKey)
            .flatMap { try? JSONDecoder().decode(HotkeyManager.Combo.self, from: $0) } ?? .default
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            Task { await self.state.toggle() }
        }
        if !hotkey.register(combo) {
            hotkeyMessage = "\(combo.label) is already in use by another app. Choose another shortcut."
        }
        // A revoked or missing token surfaces during upload; re-read the Keychain so
        // Settings stops showing "Signed in".
        notifier.onFailure = { [weak self] in
            guard let self, self.state.failureKind == .auth else { return }
            self.refreshAuth()
        }
        notifier.requestPermission()
        refreshAuth()
    }

    /// Registers `newCombo` and persists it; on failure keeps the previous shortcut and says why.
    func setCombo(_ newCombo: HotkeyManager.Combo) {
        let previous = combo
        if hotkey.register(newCombo) {
            combo = newCombo
            hotkeyMessage = nil
            if let data = try? JSONEncoder().encode(newCombo) {
                UserDefaults.standard.set(data, forKey: Self.comboKey)
            }
        } else {
            hotkey.register(previous)
            hotkeyMessage = "\(newCombo.label) is already in use by another app. Kept \(previous.label)."
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
