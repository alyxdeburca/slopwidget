import Foundation

#if os(iOS) && canImport(AuthenticationServices)
import AuthenticationServices
import UIKit
#endif

#if os(iOS) && canImport(Network)
import Network
#endif

#if os(iOS) && canImport(Network) && canImport(AuthenticationServices)

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
    private var waiter: CheckedContinuation<URL, Error>?
    private var completed: Result<URL, Error>?
    private var cancelled = false

    init(ports: [UInt16] = [1455, 1457]) {
        self.ports = ports
    }

    /// Binds the first available port and returns the redirect URI.
    func start() async throws -> URL {
        var lastError: Error = ChatGPTOAuthError.failedToStartCallbackListener
        for port in ports {
            do {
                try await bind(port: port)
                return URL(string: "http://127.0.0.1:\(port)/auth/callback")!
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
            let url = URL(string: "http://127.0.0.1\(target)")
        else {
            respond(
                connection: connection,
                status: "400 Bad Request",
                html: Self.page(title: "Bad Request", message: "The sign-in callback was malformed.")
            )
            return
        }

        let path = url.path
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

// MARK: - ASWebAuthenticationSession presenter

/// Opens the OpenAI authorization page inside `ASWebAuthenticationSession` and
/// waits for the loopback listener to receive the redirect.
@MainActor
public final class ASWebAuthenticationChatGPTPresenter: NSObject, ChatGPTAuthorizationPresenting, ASWebAuthenticationPresentationContextProviding {
    private let ports: [UInt16]
    private var session: ASWebAuthenticationSession?
    private var listener: LoopbackHTTPServer?

    public init(ports: [UInt16] = [1455, 1457]) {
        self.ports = ports
        super.init()
    }

    public func authorize(context: ChatGPTAuthorizationContext) async throws -> URL {
        let listener = LoopbackHTTPServer(ports: ports)
        self.listener = listener

        let redirectURI = try await listener.start()
        let authorizationURL = try context.authorizationURL(redirectURI: redirectURI)

        let outcome = await withTaskGroup(of: CallbackOutcome.self) { group in
            group.addTask {
                do {
                    return .callback(.success(try await listener.waitForCallback()))
                } catch {
                    return .callback(.failure(error))
                }
            }
            group.addTask { [weak self] in
                guard let self else { return .browser(.failure(ChatGPTOAuthError.cancelled)) }
                do {
                    try await self.present(authorizationURL)
                    return .browser(.success(()))
                } catch {
                    return .browser(.failure(error))
                }
            }

            var result: Result<URL, Error> = .failure(ChatGPTOAuthError.cancelled)
            while let next = await group.next() {
                switch next {
                case let .callback(callback):
                    result = callback
                    self.cancelSession()
                    group.cancelAll()
                case let .browser(browser):
                    await listener.cancel()
                    switch browser {
                    case .success:
                        result = .failure(ChatGPTOAuthError.cancelled)
                    case let .failure(error):
                        result = .failure(error)
                    }
                    group.cancelAll()
                }
                break
            }
            return result
        }

        session = nil
        self.listener = nil
        await listener.cancel()
        return try outcome.get()
    }

    private func present(_ url: URL) async throws {
        let gate = SessionGate()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { callbackURL, error in
            if let error {
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    gate.resume(throwing: ChatGPTOAuthError.cancelled)
                } else {
                    gate.resume(throwing: ChatGPTOAuthError.browserFailed(error.localizedDescription))
                }
            } else if callbackURL != nil {
                // The loopback listener normally delivers the callback. If iOS
                // ever hands it to the session instead, cancel and let the
                // listener handle it (it has already seen the same request).
                gate.resume(throwing: ChatGPTOAuthError.cancelled)
            } else {
                gate.resume(throwing: ChatGPTOAuthError.cancelled)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session

        if !session.start() {
            gate.resume(throwing: ChatGPTOAuthError.browserFailed("Could not start the sign-in browser."))
        }
        try await gate.wait()
    }

    private func cancelSession() {
        session?.cancel()
        session = nil
    }

    @objc public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }

    private enum CallbackOutcome {
        case callback(Result<URL, Error>)
        case browser(Result<Void, Error>)
    }
}

/// One-shot bridge from the session completion handler to an async waiter.
@MainActor
private final class SessionGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var pending: Result<Void, Error>?

    func wait() async throws {
        if let pending {
            return try pending.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        if let pending {
            try pending.get()
        }
    }

    func resume(throwing error: Error) {
        guard !finished else { return }
        finished = true
        pending = .failure(error)
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}

#else

/// Placeholder presenter on platforms without the loopback/browser stack.
@MainActor
public final class ASWebAuthenticationChatGPTPresenter: ChatGPTAuthorizationPresenting {
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
            presenter: ASWebAuthenticationChatGPTPresenter(ports: ports)
        )
        #else
        return ChatGPTOAuthClient(
            configuration: configuration,
            networking: networking,
            presenter: ASWebAuthenticationChatGPTPresenter(ports: ports)
        )
        #endif
    }
}
