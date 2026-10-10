import Foundation
import QuickTubeCore
import Testing

@Suite struct PKCETests {
    // RFC 7636 appendix B vector.
    @Test func challengeIsSHA256Base64URL() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierIsURLSafeAndLongEnough() {
        let pkce = PKCE.random()
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        let allowed = CharacterSet(charactersIn: alphabet)
        #expect(pkce.verifier.count == 43)
        #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(PKCE.random().verifier != pkce.verifier)
    }
}
