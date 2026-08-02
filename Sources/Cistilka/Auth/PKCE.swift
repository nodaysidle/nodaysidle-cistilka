import CryptoKit
import Foundation
import Security

/// OAuth 2.0 PKCE (RFC 7636) helpers for public native clients.
enum PKCE {
    private static let unreserved =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Cryptographically random `code_verifier` (43–128 unreserved characters).
    static func makeVerifier(length: Int = 64) -> String {
        let n = min(128, max(43, length))
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return String(bytes.map { unreserved[Int($0) % unreserved.count] })
    }

    /// S256 `code_challenge`: BASE64URL(SHA256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url encoding without padding (RFC 7636).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
