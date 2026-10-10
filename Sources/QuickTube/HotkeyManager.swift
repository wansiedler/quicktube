import AppKit
import Carbon

/// One global hotkey through Carbon; no Accessibility permission needed.
@MainActor
final class HotkeyManager {
    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32  // Carbon mask: cmdKey | optionKey | controlKey | shiftKey
        var label: String

        static let `default` = Combo(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘R")

        init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        /// nil when the event has no modifier; a bare key must not become a global hotkey.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty, let characters = event.charactersIgnoringModifiers, !characters.isEmpty
            else {
                return nil
            }
            var mask: UInt32 = 0
            var label = ""
            if flags.contains(.control) {
                mask |= UInt32(controlKey)
                label += "⌃"
            }
            if flags.contains(.option) {
                mask |= UInt32(optionKey)
                label += "⌥"
            }
            if flags.contains(.shift) {
                mask |= UInt32(shiftKey)
                label += "⇧"
            }
            if flags.contains(.command) {
                mask |= UInt32(cmdKey)
                label += "⌘"
            }
            self.init(keyCode: UInt32(event.keyCode), modifiers: mask, label: label + characters.uppercased())
        }
    }

    var onPress: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.onPress() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    func register(_ combo: Combo) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: 0x5154_5542, id: 1)  // "QTUB"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
