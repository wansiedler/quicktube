/// Turns a key press into the text the keystroke overlay shows, such as "⇧⌘S" or "⌃←".
/// Modifiers follow the macOS menu order (⌃⌥⇧⌘), like the shortcut labels in Settings.
public enum KeyComboFormatter {
    /// The modifier keys, independent of AppKit; `init(eventFlags:)` reads `NSEvent.ModifierFlags`.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        /// fn; set by AppKit for arrows and F-keys too, so it is never shown.
        public static let function = Modifiers(rawValue: 1 << 4)

        /// From the raw value of `NSEvent.ModifierFlags` (device-independent bits).
        public init(eventFlags: UInt) {
            var modifiers: Modifiers = []
            if eventFlags & (1 << 17) != 0 { modifiers.insert(.shift) }
            if eventFlags & (1 << 18) != 0 { modifiers.insert(.control) }
            if eventFlags & (1 << 19) != 0 { modifiers.insert(.option) }
            if eventFlags & (1 << 20) != 0 { modifiers.insert(.command) }
            if eventFlags & (1 << 23) != 0 { modifiers.insert(.function) }
            self = modifiers
        }
    }

    /// Virtual key codes (Carbon `kVK_*`) whose characters are control or private-use codes.
    private static let specialKeys: [UInt16: String] = [
        53: "⎋", 48: "⇥", 51: "⌫", 117: "⌦", 36: "↩", 76: "⌅", 49: "␣",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Keys shown even without ⌘, ⌃ or ⌥ in shortcuts-only mode: ⎋ ⇥ ↩ ⌅ ⌫ ⌦, the arrows and F1–F12.
    /// Space is left out, as it is part of plain typing.
    private static let standaloneKeys: Set<UInt16> = [
        53, 48, 36, 76, 51, 117, 123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

    /// Whether the keystroke pill shows this key press. With `shortcutsOnly` (the default setting) a
    /// press counts only when ⌘, ⌃ or ⌥ is held, or the key is a standalone key such as ⎋ or an arrow;
    /// ⇧ alone does not count, so plain typing (passwords included) never reaches the recording.
    public static func shouldShow(modifiers: Modifiers, keyCode: UInt16, shortcutsOnly: Bool) -> Bool {
        guard shortcutsOnly else { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option]) || standaloneKeys.contains(keyCode)
    }

    /// The combo for a key press: modifiers, then the key — a symbol for special keys, otherwise
    /// `characters` (pass `charactersIgnoringModifiers`) uppercased. Nil when there is no key to show.
    public static func format(modifiers: Modifiers, keyCode: UInt16, characters: String?) -> String? {
        let key: String
        if let special = specialKeys[keyCode] {
            key = special
        } else if let characters, let first = characters.first, !first.isWhitespace, !isControl(first) {
            key = String(first).uppercased()
        } else {
            return nil
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// Control characters and the private-use range AppKit uses for function keys (U+F700–U+F8FF).
    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || (0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
