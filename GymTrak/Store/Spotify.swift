import Foundation
import Observation
import CryptoKit

/// What the media bar shows: the track on the user's Spotify device.
struct SpotifyPlayback: Equatable, Sendable {
    var track: String
    var artist: String
    var artURL: URL?
    var isPlaying: Bool
}

/// Pure helpers for the Spotify PKCE flow (no secret needed). Kept free of state so tests can call them.
enum SpotifyAuth {
    static let callbackScheme = "gymtrak"
    static let redirectURI = "gymtrak://spotify"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    /// Client ID from Info.plist (`SpotifyClientID`, filled from Secrets.xcconfig). Nil until the Spotify app exists.
    static func clientID(from info: [String: Any]?) -> String? {
        guard let id = info?["SpotifyClientID"] as? String, !id.isEmpty, !id.contains("$(") else { return nil }
        return id
    }

    /// 64 random characters from the unreserved set (RFC 7636).
    static func makeVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    /// S256 challenge: base64url(SHA256(verifier)), no padding.
    static func challenge(for verifier: String) -> String {
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        return digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, verifier: String) -> URL? {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge(for: verifier)),
        ]
        return c.url
    }

    /// The `code` from `gymtrak://spotify?code=…`, or nil when Spotify sent an error instead.
    static func code(from callback: URL) -> String? {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "code" }?.value
    }

    /// application/x-www-form-urlencoded body.
    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(pairs.sorted().joined(separator: "&").utf8)
    }
}

/// `GET /v1/me/player` payload. `item` is null for ads or when nothing is loaded.
struct SpotifyPlayerState: Decodable, Sendable {
    let is_playing: Bool
    let item: Item?

    struct Item: Decodable, Sendable {
        let name: String
        let artists: [Named]
        let album: Album?
        struct Named: Decodable, Sendable { let name: String }
        struct Album: Decodable, Sendable { let images: [Image] }
        struct Image: Decodable, Sendable { let url: URL }
    }

    var playback: SpotifyPlayback? {
        guard let item else { return nil }
        return SpotifyPlayback(track: item.name,
                               artist: item.artists.map(\.name).joined(separator: ", "),
                               artURL: item.album?.images.first?.url,
                               isPlaying: is_playing)
    }
}

/// Spotify playback controls via the Web API (Spotify Connect). Needs Premium and an open Spotify device.
@MainActor
@Observable
final class Spotify {
    static let keychainKey = "spotify"

    private(set) var playback: SpotifyPlayback?
    private(set) var lastError: String?
    private(set) var connected = Keychain.get(Spotify.keychainKey) != nil

    /// Kept between `connect()` and the callback so the token exchange can prove it started the flow.
    private var pendingVerifier: String?

    private struct Token: Codable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    var clientID: String? { SpotifyAuth.clientID(from: Bundle.main.infoDictionary) }
    /// False until SpotifyClientID is set; the UI then shows a disabled row and `connect` does nothing.
    var configured: Bool { clientID != nil }

    // MARK: Connect

    /// `authenticate` is the view's `webAuthenticationSession.authenticate(using:callbackURLScheme:)`.
    func connect(authenticate: (URL, String) async throws -> URL) async {
        guard let id = clientID else { return }
        let verifier = SpotifyAuth.makeVerifier()
        guard let url = SpotifyAuth.authorizeURL(clientID: id, verifier: verifier) else { return }
        pendingVerifier = verifier
        do {
            let callback = try await authenticate(url, SpotifyAuth.callbackScheme)
            await finishSpotify(callback: callback)
        } catch {
            // Cancelled by the user: nothing to do.
            pendingVerifier = nil
        }
    }

    /// Finish the PKCE flow with the callback URL Spotify redirected to. Also reached from `onOpenURL` for `gymtrak://spotify`.
    func finishSpotify(callback: URL) async {
        guard let id = clientID, let verifier = pendingVerifier, let code = SpotifyAuth.code(from: callback) else {
            lastError = "Spotify sign-in didn't finish. Try Connect again."
            return
        }
        pendingVerifier = nil
        do {
            let token = try await tokenRequest([
                "grant_type": "authorization_code", "code": code, "redirect_uri": SpotifyAuth.redirectURI,
                "client_id": id, "code_verifier": verifier,
            ])
            Keychain.set(Spotify.keychainKey, try JSONEncoder().encode(token))
            connected = true
            lastError = nil
            await refresh()
        } catch {
            lastError = "Spotify: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        Keychain.delete(Spotify.keychainKey)
        connected = false
        playback = nil
        lastError = nil
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Token {
        var r = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = SpotifyAuth.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        let res = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Spotify omits refresh_token on refresh responses when it is unchanged.
        return Token(access_token: res.access_token,
                     refresh_token: res.refresh_token ?? form["refresh_token"] ?? "",
                     expires_at: Date().timeIntervalSince1970 + res.expires_in)
    }

    /// A valid access token, refreshed when it's about to expire.
    private func accessToken() async throws -> String {
        guard let id = clientID, let data = Keychain.get(Spotify.keychainKey),
              var token = try? JSONDecoder().decode(Token.self, from: data) else {
            throw URLError(.userAuthenticationRequired)
        }
        if token.expires_at < Date().timeIntervalSince1970 + 120 {
            token = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": token.refresh_token, "client_id": id])
            Keychain.set(Spotify.keychainKey, try JSONEncoder().encode(token))
        }
        return token.access_token
    }

    // MARK: Playback

    /// Reads the current player state. 204 means nothing is playing on any device.
    func refresh() async {
        guard connected else { return }
        do {
            let (status, data) = try await api("GET", "/me/player")
            switch status {
            case 200: playback = try JSONDecoder().decode(SpotifyPlayerState.self, from: data).playback
            case 204: playback = nil
            default: break
            }
        } catch {
            lastError = "Spotify: \(error.localizedDescription)"
        }
    }

    func playPause() async {
        let playing = playback?.isPlaying ?? false
        await control("PUT", playing ? "/me/player/pause" : "/me/player/play")
    }

    func next() async { await control("POST", "/me/player/next") }

    func previous() async { await control("POST", "/me/player/previous") }

    private func control(_ method: String, _ path: String) async {
        do {
            let (status, data) = try await api(method, path)
            switch status {
            case 200..<300:
                lastError = nil
                await refresh()
            case 403: lastError = "Spotify Premium needed."
            case 404: lastError = "Open Spotify on a device first."
            default: lastError = "Spotify: \(String(decoding: data, as: UTF8.self).prefix(80))"
            }
        } catch {
            lastError = "Spotify: \(error.localizedDescription)"
        }
    }

    private func api(_ method: String, _ path: String) async throws -> (Int, Data) {
        let token = try await accessToken()
        var r = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        r.httpMethod = method
        r.httpBody = Data()
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
