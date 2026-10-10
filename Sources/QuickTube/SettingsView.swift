import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("Google") {
                TextField("OAuth client ID", text: $model.clientID)
                SecureField("OAuth client secret", text: $model.clientSecret)
                HStack {
                    Button("Save client") { model.saveClient() }
                    Spacer()
                    if model.signedIn {
                        Text("Signed in").foregroundStyle(.secondary)
                        Button("Sign out") { model.signOut() }
                    } else {
                        Button("Sign in with Google") { model.signIn() }
                            .disabled(model.signingIn)
                    }
                }
                if let message = model.authMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Shortcut") {
                HStack {
                    Text(model.combo.label).font(.title3.monospaced())
                    Spacer()
                    Button(listening ? "Press keys…" : "Change") { startListening() }
                        .disabled(listening)
                }
                Text("Hold ⌘ or ⌃ (plus any other modifiers).").font(.callout).foregroundStyle(.secondary)
                if let message = model.hotkeyMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { model.refreshAuth() }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        listening = true
        // Release the global hotkey so pressing the current combo is captured, not acted on.
        model.suspendHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let combo = HotkeyManager.Combo(event: event) {
                model.setCombo(combo)
            }
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if listening {
            model.resumeHotkey()
        }
        listening = false
    }
}
