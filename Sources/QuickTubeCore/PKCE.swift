import CryptoKit
import Foundation

/// RFC 7636 code verifier and S256 challenge.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func random() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    /// Base64 with the URL-safe alphabet and no padding, as OAuth expects.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
