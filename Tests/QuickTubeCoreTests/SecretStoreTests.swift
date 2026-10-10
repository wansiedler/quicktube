import QuickTubeCore
import Testing

@Suite struct SecretStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(try store.get("k") == nil)
        try store.set("v1", for: "k")
        #expect(try store.get("k") == "v1")
        try store.set("v2", for: "k")
        #expect(try store.get("k") == "v2")
        try store.delete("k")
        #expect(try store.get("k") == nil)
        try store.delete("k")  // deleting a missing key is not an error
    }
}
