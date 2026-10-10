import QuickTubeCore
import Testing

@Suite struct KeyComboFormatterTests {
    @Test func lettersAreUppercasedWithoutModifiers() {
        #expect(KeyComboFormatter.format(modifiers: [], keyCode: 0, characters: "a") == "A")
    }

    @Test func modifiersUseTheMenuOrder() {
        let all: KeyComboFormatter.Modifiers = [.command, .shift, .option, .control]
        #expect(KeyComboFormatter.format(modifiers: all, keyCode: 1, characters: "s") == "⌃⌥⇧⌘S")
        // Same order as the menu bar and HotkeyManager labels: ⇧ before ⌘.
        #expect(
            KeyComboFormatter.format(modifiers: [.command, .shift], keyCode: 1, characters: "s") == "⇧⌘S")
    }

    @Test(arguments: [
        (UInt16(53), "⎋"), (48, "⇥"), (51, "⌫"), (117, "⌦"), (36, "↩"), (76, "⌅"), (49, "␣"),
        (123, "←"), (124, "→"), (125, "↓"), (126, "↑"), (122, "F1"), (111, "F12"),
    ])
    func specialKeysHaveSymbols(keyCode: UInt16, expected: String) {
        // Characters for special keys are control or private-use codes; the key code decides.
        #expect(KeyComboFormatter.format(modifiers: [], keyCode: keyCode, characters: "\u{F700}") == expected)
    }

    @Test func functionFlagIsNotShown() {
        // Arrow and F-keys always carry fn; showing it would only add noise.
        #expect(KeyComboFormatter.format(modifiers: [.function], keyCode: 126, characters: nil) == "↑")
        #expect(
            KeyComboFormatter.format(modifiers: [.function, .command], keyCode: 123, characters: nil) == "⌘←")
    }

    @Test func spaceWithModifiers() {
        #expect(KeyComboFormatter.format(modifiers: [.control], keyCode: 49, characters: " ") == "⌃␣")
    }

    @Test func digitsAndPunctuationStayAsTyped() {
        #expect(KeyComboFormatter.format(modifiers: [.command], keyCode: 18, characters: "1") == "⌘1")
        #expect(KeyComboFormatter.format(modifiers: [.command], keyCode: 43, characters: ",") == "⌘,")
    }

    @Test func unknownKeyWithoutCharactersGivesNil() {
        #expect(KeyComboFormatter.format(modifiers: [.command], keyCode: 200, characters: nil) == nil)
        #expect(KeyComboFormatter.format(modifiers: [], keyCode: 200, characters: "") == nil)
    }

    @Test func modifiersCanBeBuiltFromRawEventFlags() {
        // NSEvent.ModifierFlags raw values, so the app can pass `event.modifierFlags.rawValue`.
        let raw: UInt = (1 << 20) | (1 << 17) | (1 << 23)
        #expect(KeyComboFormatter.Modifiers(eventFlags: raw) == [.command, .shift, .function])
    }
}
