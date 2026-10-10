/// One-time fixes to stored hotkeys when defaults change.
public enum HotkeyMigration {
    /// Carbon `kVK_ANSI_R` and `controlKey | optionKey | cmdKey`.
    static let legacyYouTubeKeyCode: UInt32 = 0x0F
    static let legacyYouTubeModifiers: UInt32 = 0x1000 | 0x0800 | 0x0100

    /// ⌃⌥⌘R used to be the YouTube default and now belongs to "Save only": a stored YouTube combo equal
    /// to it is the old default, not a choice, and becomes nil so YouTube takes its new fallback.
    /// Any other stored combo, and nil, come back unchanged.
    public static func migratedYouTube<Combo>(
        stored: Combo?, keyCode: (Combo) -> UInt32, modifiers: (Combo) -> UInt32
    ) -> Combo? {
        guard let stored else { return nil }
        let legacy =
            keyCode(stored) == legacyYouTubeKeyCode && modifiers(stored) == legacyYouTubeModifiers
        return legacy ? nil : stored
    }
}
