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
    private static let comboKey = "hotkey.combo"

    var combo: HotkeyManager.Combo {
        didSet {
            hotkey.register(combo)
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: Self.comboKey)
            }
        }
    }
    var clientID = ""
    var clientSecret = ""
    var signedIn = false
    var authMessage: String?

    init() {
        let auth = GoogleAuth(store: KeychainStore())
        self.auth = auth
        self.state = AppState(
            recorder: Recorder(),
            uploader: YouTubeUploader(tokens: auth),
            notifier: AppNotifier())
        self.combo =
            UserDefaults.standard.data(forKey: Self.comboKey)
            .flatMap { try? JSONDecoder().decode(HotkeyManager.Combo.self, from: $0) } ?? .default
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            Task { await self.state.toggle() }
        }
        hotkey.register(combo)
        AppNotifier.requestPermission()
        refreshAuth()
    }

    func refreshAuth() {
        Task {
            signedIn = (try? await auth.isSignedIn()) ?? false
            if let client = try? await auth.client() {
                clientID = client.id
                clientSecret = client.secret
            }
        }
    }

    func saveClient() {
        let client = OAuthClient(
            id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
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
        authMessage = "Waiting for the browser…"
        Task {
            do {
                try await auth.signIn { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                signedIn = true
                authMessage = "Signed in."
            } catch {
                authMessage = AppState.message(for: error)
            }
        }
    }

    func signOut() {
        Task {
            try? await auth.signOut()
            signedIn = false
            authMessage = nil
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
