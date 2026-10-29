import Foundation

#if os(iOS) && canImport(SafariServices)
import SafariServices
import UIKit
import os
#endif

#if os(iOS) && canImport(Network) && canImport(SafariServices)

// MARK: - In-app browser presenter

/// Opens the Google authorization page in an in-app `SFSafariViewController`.
///
/// Google's installed-app client accepts a loopback redirect on any port, so we
/// bind `127.0.0.1:0` and advertise the port the OS assigned. `start()` returns
/// that exact port; it is used both for the authorization URL and for the token
/// exchange. The page is presented in-app (rather than through
/// `ASWebAuthenticationSession`) because the loopback listener must stay active
/// to receive the redirect.
@MainActor
public final class SFSafariAntigravityPresenter: NSObject, AntigravityAuthorizationPresenting, SFSafariViewControllerDelegate {
    private let ports: [UInt16]
    private var safariViewController: SFSafariViewController?
    private var listener: LoopbackHTTPServer?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completed = false

    private let logger = Logger(subsystem: "com.example.slopWidget", category: "AntigravityAuth")

    public init(ports: [UInt16] = [AntigravityOAuthConfiguration.callbackPort]) {
        self.ports = ports
        super.init()
    }

    public func authorize(context: AntigravityAuthorizationContext) async throws -> URL {
        guard context.configuration.isConfigured else {
            throw AntigravityOAuthError.notConfigured
        }

        let listener = LoopbackHTTPServer(
            ports: ports,
            callbackPath: AntigravityOAuthConfiguration.loopbackPath,
            loggerCategory: "AntigravityAuth"
        )
        self.listener = listener

        let redirectURI: URL
        do {
            redirectURI = try await listener.start()
        } catch {
            self.listener = nil
            throw Self.map(error)
        }
        let authorizationURL: URL
        do {
            authorizationURL = try context.authorizationURL(redirectURI: redirectURI)
        } catch {
            await listener.cancel()
            self.listener = nil
            throw error
        }
        logger.info(
            "Starting Google OAuth with callback \(redirectURI.absoluteString, privacy: .public)"
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.present(authorizationURL)

                Task { [weak self, listener] in
                    do {
                        let callback = try await listener.waitForCallback()
                        await self?.finish(.success(callback))
                    } catch {
                        await self?.finish(.failure(Self.map(error)))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.finish(.failure(AntigravityOAuthError.cancelled))
            }
        }
    }

    private func present(_ url: URL) {
        let controller = SFSafariViewController(url: url)
        controller.delegate = self
        safariViewController = controller

        guard let presenter = Self.topViewController() else {
            Task {
                await self.finish(.failure(
                    AntigravityOAuthError.browserFailed(
                        "Could not find a window to present the sign-in browser."
                    )
                ))
            }
            return
        }
        presenter.present(controller, animated: true)
    }

    private func finish(_ result: Result<URL, Error>) async {
        guard !completed else { return }
        completed = true

        let continuation = self.continuation
        self.continuation = nil

        await safariViewController?.dismiss(animated: true)
        safariViewController = nil

        await listener?.cancel()
        listener = nil

        switch result {
        case .success:
            logger.info("Google OAuth callback received")
        case let .failure(error):
            logger.error(
                "Google OAuth browser flow ended: \(String(describing: error), privacy: .public)"
            )
        }
        continuation?.resume(with: result)
    }

    public nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in
            await self?.finish(.failure(AntigravityOAuthError.cancelled))
        }
    }

    /// The shared loopback server reports the ChatGPT error type; translate the
    /// transport-level cases into Antigravity's error domain.
    private static func map(_ error: Error) -> AntigravityOAuthError {
        if let error = error as? AntigravityOAuthError {
            return error
        }
        guard let error = error as? ChatGPTOAuthError else {
            return .browserFailed(error.localizedDescription)
        }
        switch error {
        case .cancelled:
            return .cancelled
        case .failedToStartCallbackListener:
            return .failedToStartCallbackListener
        case .unsupportedPlatform:
            return .unsupportedPlatform
        default:
            return .browserFailed(error.localizedDescription)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard var controller = windows.first(where: \.isKeyWindow)?.rootViewController
                ?? windows.first?.rootViewController
        else { return nil }

        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

#else

/// Placeholder presenter on platforms without the loopback/browser stack.
@MainActor
public final class SFSafariAntigravityPresenter: AntigravityAuthorizationPresenting {
    public init(ports: [UInt16] = [AntigravityOAuthConfiguration.callbackPort]) {}

    public func authorize(context: AntigravityAuthorizationContext) async throws -> URL {
        throw AntigravityOAuthError.unsupportedPlatform
    }
}

#endif

// MARK: - Factory

public enum AntigravityOAuthClientFactory {
    /// Production client: real dynamic-port loopback listener, real browser,
    /// real Google token endpoint.
    @MainActor
    public static func makeDefault(
        configuration: AntigravityOAuthConfiguration = .defaultConfiguration(),
        networking: any AntigravityOAuthNetworking = URLSessionAntigravityOAuthNetworking(),
        ports: [UInt16] = [AntigravityOAuthConfiguration.callbackPort]
    ) -> AntigravityOAuthClient {
        AntigravityOAuthClient(
            configuration: configuration,
            networking: networking,
            presenter: SFSafariAntigravityPresenter(ports: ports)
        )
    }
}
