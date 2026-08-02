import XCTest
@testable import Cistilka

final class PKCETests: XCTestCase {
    func testVerifierLengthAtLeast43() {
        for _ in 0..<20 {
            let verifier = PKCE.makeVerifier()
            XCTAssertGreaterThanOrEqual(
                verifier.count,
                43,
                "RFC 7636 code_verifier must be at least 43 characters"
            )
            XCTAssertLessThanOrEqual(verifier.count, 128)
            XCTAssertTrue(
                verifier.unicodeScalars.allSatisfy { Self.unreserved.contains($0) },
                "verifier must be unreserved characters only"
            )
        }
    }

    func testChallengeIsDeterministicForFixedVerifier() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let a = PKCE.challenge(for: verifier)
        let b = PKCE.challenge(for: verifier)
        XCTAssertEqual(a, b)
        // RFC 7636 Appendix B example (S256)
        XCTAssertEqual(a, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeIsBase64URLWithoutPadding() {
        let challenge = PKCE.challenge(for: PKCE.makeVerifier())
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertFalse(challenge.contains("="))
    }

    func testOAuthConfigLoadDoesNotCrashWhenMissing() {
        let config = OAuthConfig.load()
        // Without Config/OAuth.plist or bundled resource, fields may be nil.
        _ = config.googleClientID
        _ = config.microsoftClientID
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
