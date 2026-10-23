#if !APPSTORE
import AppKit
import CryptoKit
import Foundation
import Network

/// Google sign-in for the YouTube Data and Analytics APIs, the desktop-app way: the browser opens
/// Google's consent page, Google redirects to a one-shot server on 127.0.0.1, and the code is
/// exchanged (with PKCE) for a refresh token kept in the Keychain.
///
/// The OAuth client (a "Desktop app" client of the user's own Google Cloud project) is pasted in
/// the YouTube page; nothing here ships with a Google project of its own.
@MainActor
final class YouTubeAuth: ObservableObject {
    static let shared = YouTubeAuth()

    static let clientIdKey = "youtube_oauth_client_id"
    static let clientSecretKey = "youtube_oauth_client_secret"
    static let refreshTokenKey = "youtube_refresh_token"

    static let scopes = [
        "https://www.googleapis.com/auth/youtube.readonly",
        "https://www.googleapis.com/auth/yt-analytics.readonly",
        "https://www.googleapis.com/auth/yt-analytics-monetary.readonly",
    ]

    @Published private(set) var signedIn = KeychainStore.shared.get(YouTubeAuth.refreshTokenKey) != nil
    @Published private(set) var signingIn = false
    @Published var error: String?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var listener: NWListener?

    var clientId: String { KeychainStore.shared.get(Self.clientIdKey) ?? "" }
    var hasClient: Bool { !clientId.isEmpty && !(KeychainStore.shared.get(Self.clientSecretKey) ?? "").isEmpty }

    func saveClient(id: String, secret: String) {
        let i = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !i.isEmpty { KeychainStore.shared.set(Self.clientIdKey, value: i) }
        if !s.isEmpty { KeychainStore.shared.set(Self.clientSecretKey, value: s) }
        objectWillChange.send()
    }

    func signOut() {
        KeychainStore.shared.remove(Self.refreshTokenKey)
        accessToken = nil
        accessExpiry = .distantPast
        signedIn = false
    }

    // MARK: Sign in

    func signIn() {
        guard hasClient, !signingIn else { return }
        error = nil
        signingIn = true
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        do {
            let l = try NWListener(using: .tcp, on: .any)
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn, verifier: verifier, state: state) }
            }
            l.stateUpdateHandler = { [weak self] st in
                guard case .ready = st, let port = l.port?.rawValue else { return }
                Task { @MainActor in self?.openConsent(port: port, challenge: challenge, state: state) }
            }
            l.start(queue: .main)
        } catch {
            fail("Couldn't start the sign-in: \(error.localizedDescription)")
        }
    }

    private var redirectURI = ""

    private func openConsent(port: UInt16, challenge: String, state: String) {
        redirectURI = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(c.url!)
        // Give up after 5 minutes so the port doesn't stay open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.signingIn else { return }
            self.fail("The sign-in timed out. Try again.")
        }
    }

    private func handle(_ conn: NWConnection, verifier: String, state: String) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = request.split(separator: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://x\(path)")?.queryItems ?? []
            func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
            let ok = q("code") != nil && q("state") == state
            let body = ok
                ? "<h2 style='font-family:-apple-system'>Coucou is connected to YouTube. You can close this tab.</h2>"
                : "<h2 style='font-family:-apple-system'>Sign-in cancelled. You can close this tab.</h2>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { @MainActor in
                guard let self, self.signingIn else { return }
                guard path.hasPrefix("/?") else { return }  // ignore /favicon.ico
                if let code = q("code"), q("state") == state {
                    await self.exchange(code: code, verifier: verifier)
                } else {
                    self.fail(q("error").map { "Google said: \($0)" } ?? "Sign-in cancelled.")
                }
            }
        }
    }

    private func exchange(code: String, verifier: String) async {
        do {
            let json = try await tokenRequest([
                "code": code,
                "client_id": clientId,
                "client_secret": KeychainStore.shared.get(Self.clientSecretKey) ?? "",
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier,
            ])
            guard let refresh = json["refresh_token"] as? String else {
                throw YouTubeAPIError.message("Google didn't return a refresh token.")
            }
            KeychainStore.shared.set(Self.refreshTokenKey, value: refresh)
            store(json)
            signedIn = true
            finish()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        error = message
        finish()
    }

    private func finish() {
        signingIn = false
        listener?.cancel()
        listener = nil
    }

    // MARK: Tokens

    /// A valid access token, refreshed when needed.
    func token() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = KeychainStore.shared.get(Self.refreshTokenKey) else {
            throw YouTubeAPIError.message("Not signed in to YouTube.")
        }
        let json = try await tokenRequest([
            "refresh_token": refresh,
            "client_id": clientId,
            "client_secret": KeychainStore.shared.get(Self.clientSecretKey) ?? "",
            "grant_type": "refresh_token",
        ])
        store(json)
        guard let accessToken else { throw YouTubeAPIError.message("Google didn't return an access token.") }
        return accessToken
    }

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        accessExpiry = Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3000))
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let reason = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP error"
            if json["error"] as? String == "invalid_grant" { signOut() }
            throw YouTubeAPIError.message("Google sign-in failed: \(reason)")
        }
        return json
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

enum YouTubeAPIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
#endif
