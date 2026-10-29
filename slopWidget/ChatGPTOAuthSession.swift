import Foundation

#if os(iOS) && canImport(SafariServices)
import SafariServices
import UIKit
import os
#endif

#if os(iOS) && canImport(Network)
import Network
#endif

#if os(iOS) && canImport(Network) && canImport(SafariServices)

// MARK: - Loopback callback listener

/// Short-lived HTTP listener for the OAuth loopback redirect.
///
/// OpenAI's native client only registers `http://127.0.0.1:1455/auth/callback`
/// (with 1457 as a fallback), so a custom URL scheme cannot be used. The listener
/// binds before the browser is opened; the redirect lands here and the captured
/// code is handed back to `ChatGPTOAuthClient`.
actor LoopbackHTTPServer {
    private let ports: [UInt16]
    private var listener: NWListener?
    private var baseURL: URL?
    private var waiter: CheckedContinuation<URL, Error>?
    private var completed: Result<URL, Error>?
    private var cancelled = false
    private let logger = Logger(subsystem: "com.example.slopWidget", category: "ChatGPTAuth")

    init(ports: [UInt16] = [1455, 1457]) {
        self.ports = ports
    }

    /// Binds the first available port and returns the redirect URI.
    func start() async throws -> URL {
        var lastError: Error = ChatGPTOAuthError.failedToStartCallbackListener
        for port in ports {
            do {
                try await bind(port: port)
                logger.info("Loopback listener bound on 127.0.0.1:\(port)")
                let baseURL = URL(string: "http://127.0.0.1:\(port)")!
                self.baseURL = baseURL
                return URL(string: "/auth/callback", relativeTo: baseURL)!.absoluteURL
            } catch {
                lastError = error
            }
        }
        _ = lastError
        throw ChatGPTOAuthError.failedToStartCallbackListener
    }

    /// Suspends until OpenAI redirects, or until `cancel()` is called.
    func waitForCallback() async throws -> URL {
        if let completed {
            return try completed.get()
        }
        if cancelled {
            throw ChatGPTOAuthError.cancelled
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }

    func cancel() {
        cancelled = true
        listener?.cancel()
        listener = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: ChatGPTOAuthError.cancelled)
        }
    }

    private func bind(port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ChatGPTOAuthError.failedToStartCallbackListener
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: nwPort
        )

        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        let ready = ReadyGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.succeed()
            case let .failed(error):
                Logger(subsystem: "com.example.slopWidget", category: "ChatGPTAuth")
                    .error("Loopback listener failed: \(String(describing: error), privacy: .public)")
                ready.fail(error)
            case .cancelled:
                ready.fail(ChatGPTOAuthError.failedToStartCallbackListener)
            default:
                break
            }
        }
        listener.start(queue: .main)
        try await ready.wait()

        // The listener may fail immediately after reporting ready; a later
        // cancellation is surfaced through `waitForCallback`.
        if cancelled {
            listener.cancel()
            self.listener = nil
            throw ChatGPTOAuthError.cancelled
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { await self?.handle(request: request, connection: connection) }
        }
    }

    private func handle(request: String, connection: NWConnection) {
        guard
            let requestLine = request.split(separator: "\r\n").first,
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init),
            let baseURL,
            let url = URL(string: target, relativeTo: baseURL)?.absoluteURL
        else {
            respond(
                connection: connection,
                status: "400 Bad Request",
                html: Self.page(title: "Bad Request", message: "The sign-in callback was malformed.")
            )
            return
        }

        let path = url.path
        logger.info("Loopback request received for path \(path, privacy: .public)")
        if path == "/auth/callback" {
            respond(
                connection: connection,
                status: "200 OK",
                html: Self.page(
                    title: "Signed in",
                    message: "You can close this window and return to slopWidget."
                )
            )
            finish(.success(url))
        } else if path == "/cancel" {
            respond(
                connection: connection,
                status: "200 OK",
                html: Self.page(title: "Sign-in cancelled", message: "You can return to slopWidget.")
            )
            finish(.failure(ChatGPTOAuthError.cancelled))
        } else {
            respond(
                connection: connection,
                status: "404 Not Found",
                html: Self.page(title: "Not Found", message: "Unknown callback path.")
            )
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard completed == nil else { return }
        completed = result
        listener?.cancel()
        listener = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
    }

    private func respond(connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1115; color: #f5f5f5;
                   display: flex; min-height: 100vh; align-items: center; justify-content: center; margin: 0; }
            main { max-width: 28rem; padding: 2rem; text-align: center; }
            h1 { font-size: 1.35rem; margin-bottom: .5rem; }
            p { color: #b8bcc7; line-height: 1.5; }
          </style>
        </head>
        <body><main><h1>\(title)</h1><p>\(message)</p></main></body>
        </html>
        """
    }
}

/// Resumes a continuation exactly once from Network framework callbacks.
private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var finished = false

    init() {}

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ newResult: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        result = newResult
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: newResult)
    }
}

// MARK: - In-app browser presenter

/// Opens the OpenAI authorization page in an in-app `SFSafariViewController`.
///
/// The loopback redirect only works while the app is running. Presenting the
/// page in `ASWebAuthenticationSession` moves the host app to the background,
/// which suspends the listener and drops the callback. `SFSafariViewController`
/// is hosted by this app, so the app stays active and can serve the redirect.
@MainActor
public final class SFSafariChatGPTPresenter: NSObject, ChatGPTAuthorizationPresenting, SFSafariViewControllerDelegate {
    private let ports: [UInt16]
    private var safariViewController: SFSafariViewController?
    private var listener: LoopbackHTTPServer?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completed = false

    private let logger = Logger(subsystem: "com.example.slopWidget", category: "ChatGPTAuth")

    public init(ports: [UInt16] = [1455, 1457]) {
        self.ports = ports
        super.init()
    }

    public func authorize(context: ChatGPTAuthorizationContext) async throws -> URL {
        let listener = LoopbackHTTPServer(ports: ports)
        self.listener = listener

        let redirectURI = try await listener.start()
        let authorizationURL = try context.authorizationURL(redirectURI: redirectURI)
        logger.info("Starting ChatGPT OAuth with callback \(redirectURI.absoluteString, privacy: .public)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.present(authorizationURL)

                Task { [weak self, listener] in
                    do {
                        let callback = try await listener.waitForCallback()
                        await self?.finish(.success(callback))
                    } catch {
                        await self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.finish(.failure(ChatGPTOAuthError.cancelled))
            }
        }
    }

    private func present(_ url: URL) {
        let controller = SFSafariViewController(url: url)
        controller.delegate = self
        safariViewController = controller

        guard let presenter = Self.topViewController() else {
            Task { await self.finish(.failure(ChatGPTOAuthError.browserFailed("Could not find a window to present the sign-in browser."))) }
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
            logger.info("ChatGPT OAuth callback received")
        case let .failure(error):
            logger.error("ChatGPT OAuth browser flow ended: \(String(describing: error), privacy: .public)")
        }
        continuation?.resume(with: result)
    }

    public nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in
            await self?.finish(.failure(ChatGPTOAuthError.cancelled))
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
public final class SFSafariChatGPTPresenter: ChatGPTAuthorizationPresenting {
    public init(ports: [UInt16] = [1455, 1457]) {}

    public func authorize(context: ChatGPTAuthorizationContext) async throws -> URL {
        throw ChatGPTOAuthError.unsupportedPlatform
    }
}

#endif

// MARK: - Factory

public enum ChatGPTOAuthClientFactory {
    /// Production client: real loopback listener, real browser, real token endpoint.
    @MainActor
    public static func makeDefault(
        configuration: ChatGPTOAuthConfiguration = .codex(),
        networking: any ChatGPTOAuthNetworking = URLSessionChatGPTOAuthNetworking(),
        ports: [UInt16] = [1455, 1457]
    ) -> ChatGPTOAuthClient {
        #if os(iOS)
        return ChatGPTOAuthClient(
            configuration: configuration,
            networking: networking,
            presenter: SFSafariChatGPTPresenter(ports: ports)
        )
        #else
        return ChatGPTOAuthClient(
            configuration: configuration,
            networking: networking,
            presenter: SFSafariChatGPTPresenter(ports: ports)
        )
        #endif
    }
}
