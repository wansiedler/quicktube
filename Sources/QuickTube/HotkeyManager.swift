import AppKit
import Carbon
import QuickTubeCore

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
        static let telegramDefault = Combo(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘T")
        static let driveDefault = Combo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘D")
        static let slackDefault = Combo(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘S")
        static let pauseDefault = Combo(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            label: "⌃⌥⌘P")

        static func fallback(for destination: Destination) -> Combo {
            switch destination {
            case .youtube: .default
            case .telegram: .telegramDefault
            case .drive: .driveDefault
            case .slack: .slackDefault
            }
        }

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

    /// Called with the slot number of the hotkey that fired.
    var onPress: (UInt32) -> Void = { _ in }
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var active: [UInt32: Combo] = [:]

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let slot = hotKeyID.id
            MainActor.assumeIsolated { manager.onPress(slot) }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr {
            print("QuickTube: InstallEventHandler failed with status \(status)")
        }
    }

    /// Replaces the hotkey in `slot`. False when the system refuses the combo (e.g. taken by another
    /// app); nothing is registered in that slot then.
    @discardableResult
    func register(_ combo: Combo, slot: UInt32) -> Bool {
        unregister(slot)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5154_5542, id: slot)  // "QTUB"
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            print("QuickTube: RegisterEventHotKey(\(combo.label)) failed with status \(status)")
            return false
        }
        refs[slot] = ref
        active[slot] = combo
        return true
    }

    /// Releases the hotkey in `slot` for good; `resume()` does not bring it back.
    func remove(slot: UInt32) {
        unregister(slot)
        active[slot] = nil
    }

    /// Temporarily releases every hotkey, e.g. while Settings records a new combo.
    func suspend() {
        for slot in Array(refs.keys) { unregister(slot) }
    }

    /// Re-registers every combo that was registered before `suspend()`.
    func resume() {
        for (slot, combo) in active where refs[slot] == nil {
            register(combo, slot: slot)
        }
    }

    private func unregister(_ slot: UInt32) {
        if let ref = refs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }
}
