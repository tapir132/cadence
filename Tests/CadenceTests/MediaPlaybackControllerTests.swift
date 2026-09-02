import Testing
@testable import Cadence

@Test func disabledMediaPauseNeverTouchesAPlayer() {
    var session = MediaPauseSession()
    var pauseAttempts: [SupportedMediaPlayer] = []

    session.begin(enabled: false) { player in
        pauseAttempts.append(player)
        return true
    }

    #expect(pauseAttempts.isEmpty)
    #expect(session.pausedPlayers.isEmpty)
}

@Test func mediaPauseResumesOnlyPlayersPausedByCadence() {
    var session = MediaPauseSession()
    var resumed: [SupportedMediaPlayer] = []

    session.begin(enabled: true) { player in
        player == .music
    }
    session.end { player in
        resumed.append(player)
    }

    #expect(resumed == [.music])
    #expect(session.pausedPlayers.isEmpty)
}
