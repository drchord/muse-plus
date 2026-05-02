import Foundation
import UIKit
import CryptoKit

// Spotify Web API + PKCE — no SpotifyiOS.xcframework required.
//
// One-time setup in developer.spotify.com → your app → Edit Settings:
//   Add redirect URI: muse-monitor://callback

final class SpotifyManager: NSObject, ObservableObject {
    static let shared = SpotifyManager()

    private let clientID    = "dd746e8ec4e94dd2bc099a66efbe8157"
    private let redirectURI = "muse-monitor://callback"
    private let scopes      = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    @Published var isConnected  = false
    @Published var currentTrack = ""
    @Published var isPaused     = true

    private var accessToken:  String?
    private var refreshToken: String?
    private var tokenExpiry:  Date?
    private var codeVerifier: String?
    private var pollTimer:    Timer?

    // MARK: - Public API

    func authorize() {
        let verifier  = makeVerifier()
        codeVerifier  = verifier
        let challenge = makeChallenge(verifier)

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "response_type",         value: "code"),
            .init(name: "client_id",             value: clientID),
            .init(name: "scope",                 value: scopes),
            .init(name: "redirect_uri",          value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge",        value: challenge),
        ]
        guard let url = c.url else { return }
        UIApplication.shared.open(url)
    }

    func handleCallback(_ url: URL) {
        guard url.scheme == "muse-monitor",
              let comps    = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code     = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = codeVerifier else { return }
        exchangeCode(code, verifier: verifier)
    }

    func disconnect() {
        accessToken  = nil
        refreshToken = nil
        tokenExpiry  = nil
        isConnected  = false
        currentTrack = ""
        isPaused     = true
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func play()  { command("play")  }
    func pause() { command("pause") }

    // MARK: - Playback commands

    private func command(_ endpoint: String) {
        withToken { [weak self] token in
            guard let token else { return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(endpoint)")!)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 204 else { return }
                DispatchQueue.main.async { self?.isPaused = (endpoint == "pause") }
            }.resume()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.fetchNowPlaying()
        }
    }

    private func fetchNowPlaying() {
        withToken { [weak self] token in
            guard let token else { return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
                guard let data,
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let item      = json["item"] as? [String: Any],
                      let name      = item["name"] as? String,
                      let artists   = item["artists"] as? [[String: Any]],
                      let artist    = artists.first?["name"] as? String else { return }
                let playing = json["is_playing"] as? Bool ?? false
                DispatchQueue.main.async {
                    self?.currentTrack = "\(name) — \(artist)"
                    self?.isPaused     = !playing
                }
            }.resume()
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, verifier: String) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  redirectURI,
            "client_id":     clientID,
            "code_verifier": verifier,
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            self?.applyTokenResponse(data)
        }.resume()
    }

    private func refreshIfNeeded() {
        guard let refresh = refreshToken else { disconnect(); return }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "grant_type":    "refresh_token",
            "refresh_token": refresh,
            "client_id":     clientID,
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            self?.applyTokenResponse(data)
        }.resume()
    }

    private func applyTokenResponse(_ data: Data?) {
        guard let data,
              let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access    = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else { return }
        DispatchQueue.main.async {
            self.accessToken = access
            self.tokenExpiry = Date().addingTimeInterval(Double(expiresIn) - 60)
            if let r = json["refresh_token"] as? String { self.refreshToken = r }
            if !self.isConnected {
                self.isConnected = true
                self.startPolling()
                self.fetchNowPlaying()
            }
        }
    }

    // Token available now, or nil (caller skips; refresh fires in background for next call)
    private func withToken(_ completion: @escaping (String?) -> Void) {
        if let t = accessToken, let exp = tokenExpiry, Date() < exp {
            completion(t)
        } else {
            if refreshToken != nil { refreshIfNeeded() }
            completion(nil)
        }
    }

    // MARK: - PKCE helpers

    private func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formBody(_ params: [String: String]) -> Data {
        params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}
