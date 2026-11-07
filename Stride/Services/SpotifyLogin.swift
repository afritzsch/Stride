import AuthenticationServices
import Foundation
import Network
import UIKit

/// Runs Spotify's login in an `ASWebAuthenticationSession` and catches the redirect to
/// `http://127.0.0.1:<port>/callback` with a one-shot listener in the app. Spotify accepts only https or loopback
/// redirect URIs (no custom schemes), and the app is in the foreground while the login sheet is up, so the listener
/// can answer. Once the code arrives the sheet is closed.
final class SpotifyLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    /// The authorization code, after checking `state`.
    func run(url: URL, state: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                try startListener(state: state)
            } catch {
                finish(.failure(SpotifyClient.Failure.login("Stride couldn't listen for Spotify's answer (\(error.localizedDescription)).")))
                return
            }
            // The scheme never comes back (the redirect is http); the listener completes the login instead.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "stride") { [weak self] _, error in
                Task { @MainActor in
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        self?.finish(.failure(CancellationError()))
                    } else if let error {
                        self?.finish(.failure(error))
                    }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                finish(.failure(SpotifyClient.Failure.login("Stride couldn't open the Spotify login.")))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        return ASPresentationAnchor(windowScene: scenes.first!)
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        session?.cancel()
        session = nil
        continuation.resume(with: result)
    }

    private func startListener(state: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: SpotifyClient.redirectPort)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let result = SpotifyClient.callback(request: request, state: state)
                let page = switch result {
                case .success: "<h2>Spotify is connected.</h2><p>You can go back to Stride.</p>"
                case .failure(let error): "<h2>Spotify wasn't connected.</h2><p>\(error.localizedDescription)</p>"
                case nil: "<p>Waiting for Spotify…</p>"
                }
                let body = "<!doctype html><meta name=viewport content='width=device-width'><body style='font:17px -apple-system;padding:24px'>\(page)</body>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    Task { @MainActor in
                        // Let the page show for a moment before the sheet closes.
                        try? await Task.sleep(for: .milliseconds(600))
                        if let result { self?.finish(result) }
                    }
                })
            }
        }
        listener.stateUpdateHandler = { [weak self] newState in
            if case .failed(let error) = newState {
                Task { @MainActor in
                    self?.finish(.failure(SpotifyClient.Failure.login("Stride couldn't listen for Spotify's answer (\(error.localizedDescription)).")))
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }
}
