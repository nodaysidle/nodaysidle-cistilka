import AppKit
import AuthenticationServices
import Foundation

/// Shared `ASWebAuthenticationSession` helper with a safe presentation anchor
/// and single-resume continuation (avoids traps on cancel / SafariLaunchAgent).
enum WebAuthSession {
    enum WebAuthError: Error, LocalizedError, Sendable {
        case couldNotStart
        case noCallbackURL
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotStart:
                return "Could not start the sign-in browser session."
            case .noCallbackURL:
                return "Sign-in did not return a callback URL."
            case .cancelled:
                return "Sign-in was cancelled."
            }
        }
    }

    /// Runs an OAuth browser session. Must be called from the main actor.
    @MainActor
    static func start(url: URL, callbackScheme: String) async throws -> URL {
        let context = PresentationContext()
        // Keep context alive for the session lifetime via the continuation box.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let box = ResumeBox(continuation: continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionErrorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    {
                        box.resume(throwing: WebAuthError.cancelled)
                    } else {
                        box.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    box.resume(throwing: WebAuthError.noCallbackURL)
                    return
                }
                box.resume(returning: callbackURL)
            }
            session.presentationContextProvider = context
            // Prefer system browser sheet; ephemeral can fail more often on some macOS builds.
            session.prefersEphemeralWebBrowserSession = false
            // Retain context until callback fires.
            box.context = context
            box.session = session
            if !session.start() {
                box.resume(throwing: WebAuthError.couldNotStart)
            }
        }
    }

    /// Thread-safe single-shot resume for the auth continuation.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        var context: PresentationContext?
        var session: ASWebAuthenticationSession?

        init(continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func resume(returning url: URL) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: url)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    @MainActor
    final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        /// Optional window we create only if the app has no usable window yet.
        private var fallbackWindow: NSWindow?

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            if let key = NSApplication.shared.keyWindow, key.isVisible {
                return key
            }
            if let main = NSApplication.shared.mainWindow, main.isVisible {
                return main
            }
            if let visible = NSApplication.shared.windows.first(where: \.isVisible) {
                return visible
            }
            if let any = NSApplication.shared.windows.first {
                any.makeKeyAndOrderFront(nil)
                return any
            }
            // Never return a bare `ASPresentationAnchor()` — that can SIGTRAP on modern macOS
            // when SafariLaunchAgent tries to present the auth session.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Cistilka Sign-In"
            window.center()
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            fallbackWindow = window
            return window
        }
    }
}
