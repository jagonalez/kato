import AppKit

/// Polls Spotify and Apple Music for playback state (2 s timer) and
/// reports changes via `onChange`. Each app is probed only while
/// NSRunningApplication says it's alive — an Apple event to a quit app
/// would launch it. The first probe per app triggers the Automation
/// (TCC) consent prompt; denial just reads as "not playing".
@MainActor
final class MusicMonitor {
    private struct Player {
        let bundleID: String
        let tellName: String
    }

    private static let players = [
        Player(bundleID: "com.spotify.client", tellName: "Spotify"),
        Player(bundleID: "com.apple.Music", tellName: "Music"),
    ]

    private let onChange: (Bool) -> Void
    private var timer: Timer?
    private(set) var isPlaying = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let playing = Self.players.contains { player in
            guard !NSRunningApplication
                .runningApplications(withBundleIdentifier: player.bundleID).isEmpty
            else { return false }
            let source = "tell application \"\(player.tellName)\" to get player state as string"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil && result?.stringValue == "playing"
        }
        if playing != isPlaying {
            isPlaying = playing
            onChange(playing)
        }
    }
}
