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

        /// nil unless ⌘ or ⌃ is held; bare, ⇧-only or ⌥-only keys would hijack ordinary typing.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags.contains(.command) || flags.contains(.control),
                let characters = event.charactersIgnoringModifiers, !characters.isEmpty
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
    private var active: Combo?

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.onPress() }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr {
            print("QuickTube: InstallEventHandler failed with status \(status)")
        }
    }

    /// Replaces the registered hotkey. False when the system refuses the combo (e.g. taken by another app);
    /// nothing is registered then.
    @discardableResult
    func register(_ combo: Combo) -> Bool {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5154_5542, id: 1)  // "QTUB"
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            print("QuickTube: RegisterEventHotKey(\(combo.label)) failed with status \(status)")
            return false
        }
        hotKeyRef = ref
        active = combo
        return true
    }

    /// Temporarily releases the hotkey, e.g. while Settings records a new combo.
    func suspend() {
        unregister()
    }

    /// Re-registers the last successfully registered combo if it is currently released.
    func resume() {
        guard hotKeyRef == nil, let active else { return }
        register(active)
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
