import Foundation

// Stub — compiles without SpotifyiOS.xcframework.
// Replace with full implementation once Frameworks/SpotifyiOS.xcframework is in place.

final class SpotifyManager: NSObject, ObservableObject {
    static let shared = SpotifyManager()

    @Published var isConnected   = false
    @Published var currentTrack  = ""
    @Published var isPaused      = true

    func authorize()              { }   // no-op until SDK linked
    func handleCallback(_ url: URL) { }
    func disconnect()             { }
    func play()                   { }
    func pause()                  { }
}
