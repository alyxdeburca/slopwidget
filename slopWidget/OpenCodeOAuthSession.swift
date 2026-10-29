import Foundation

#if os(iOS) && canImport(SafariServices)
import SafariServices
import UIKit
#endif

#if os(iOS) && canImport(SafariServices)

// MARK: - In-app browser presenter

/// Opens OpenCode's device-verification page in an in-app
/// `SFSafariViewController`.
///
/// The device flow never redirects back into the app, so unlike the ChatGPT
/// loopback flow this presenter does not need a listener or URL-scheme
/// registration. It is dismissed once the poller receives the grant (or the
/// user cancels/closes it).
@MainActor
public final class SFSafariOpenCodePresenter: NSObject, OpenCodeDeviceAuthorizationPresenting,
    SFSafariViewControllerDelegate {
    private var safariViewController: SFSafariViewController?

    public override init() {
        super.init()
    }

    public func present(verificationURL: URL) async throws {
        guard safariViewController == nil else { return }
        guard let presenter = Self.topViewController() else {
            throw OpenCodeOAuthError.browserFailed("Could not find a window to present the sign-in browser.")
        }

        let controller = SFSafariViewController(url: verificationURL)
        controller.delegate = self
        safariViewController = controller
        presenter.present(controller, animated: true, completion: nil)
    }

    public func dismiss() async {
        guard let controller = safariViewController else { return }
        safariViewController = nil
        controller.delegate = nil
        controller.dismiss(animated: true, completion: nil)
    }

    public nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in
            // The poller keeps running; the user can retry on another device.
            // Clearing the reference lets a later sign-in present a fresh page.
            self?.safariViewController = nil
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

/// No-op presenter on platforms without SafariServices. The status text still
/// shows the code and URL so the flow remains usable.
@MainActor
public final class SFSafariOpenCodePresenter: OpenCodeDeviceAuthorizationPresenting {
    public init() {}

    public func present(verificationURL: URL) async throws {
        throw OpenCodeOAuthError.unsupportedPlatform
    }

    public func dismiss() async {}
}

#endif
