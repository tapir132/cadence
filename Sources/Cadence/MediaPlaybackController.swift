@preconcurrency import AppKit
import Foundation

enum SupportedMediaPlayer: String, CaseIterable, Hashable, Sendable {
    case music
    case spotify

    var bundleIdentifier: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var title: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

/// Tracks ownership of a pause independently from app automation. Cadence
/// resumes only players it observed playing and successfully paused itself.
struct MediaPauseSession {
    private(set) var pausedPlayers: [SupportedMediaPlayer] = []

    mutating func begin(
        enabled: Bool,
        pause: (SupportedMediaPlayer) -> Bool
    ) {
        guard enabled, pausedPlayers.isEmpty else { return }
        for player in SupportedMediaPlayer.allCases where pause(player) {
            pausedPlayers.append(player)
        }
    }

    mutating func end(resume: (SupportedMediaPlayer) -> Void) {
        let players = pausedPlayers
        pausedPlayers.removeAll(keepingCapacity: true)
        for player in players { resume(player) }
    }
}

/// macOS has a public API for receiving Now Playing commands in the app that
/// owns playback, but not for sending a pause command to an arbitrary player.
/// Music and Spotify both publish scripting dictionaries, so Apple events give
/// Cadence an explicit `pause` operation rather than an unsafe play/pause
/// toggle that could start media which was already stopped.
@MainActor
final class MediaPlaybackController {
    private var session = MediaPauseSession()

    func begin(enabled: Bool) {
        session.begin(enabled: enabled) { player in
            guard Self.isRunning(player) else { return false }
            return Self.run(command: .pause, for: player)
        }
    }

    func end() {
        session.end { player in
            guard Self.isRunning(player) else { return }
            _ = Self.run(command: .resume, for: player)
        }
    }

    private enum PlaybackCommand {
        case pause
        case resume
    }

    private static func isRunning(_ player: SupportedMediaPlayer) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: player.bundleIdentifier
        ).isEmpty
    }

    private static func run(
        command: PlaybackCommand,
        for player: SupportedMediaPlayer
    ) -> Bool {
        let action: String
        let success: String
        switch command {
        case .pause:
            action = """
                if player state is playing then
                    pause
                    return "paused"
                end if
                """
            success = "paused"
        case .resume:
            action = """
                if player state is paused then
                    play
                    return "resumed"
                end if
                """
            success = "resumed"
        }

        let source = """
            tell application id "\(player.bundleIdentifier)"
                \(action)
            end tell
            return "unchanged"
            """
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog(
                "Cadence could not control %@ playback: %@",
                player.title,
                String(describing: errorInfo)
            )
            return false
        }
        return result.stringValue == success
    }
}
