import QuickTubeCore
import Testing

@Suite struct HotkeyMigrationTests {
    private struct Stored: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    private func migrate(_ stored: Stored?) -> Stored? {
        HotkeyMigration.migratedYouTube(stored: stored, keyCode: \.keyCode, modifiers: \.modifiers)
    }

    @Test func oldDefaultIsDropped() {
        #expect(migrate(Stored(keyCode: 0x0F, modifiers: 0x1900)) == nil)
    }

    @Test func otherCombosAreKept() {
        let other = Stored(keyCode: 0x10, modifiers: 0x1900)
        #expect(migrate(other) == other)
        let differentModifiers = Stored(keyCode: 0x0F, modifiers: 0x0900)
        #expect(migrate(differentModifiers) == differentModifiers)
    }

    @Test func nilStaysNil() {
        #expect(migrate(nil) == nil)
    }
}
