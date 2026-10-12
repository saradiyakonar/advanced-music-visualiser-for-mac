import Foundation
import Testing
@testable import VisualiserCore

@Suite struct NowPlayingTests {
    let us = "\u{1F}"

    func track(_ app: PlayerApp, _ id: String, _ state: PlayerState) -> TrackInfo {
        TrackInfo(app: app, id: id, title: "T\(id)", artist: "A", album: "B", state: state, artworkURL: nil)
    }

    @Test func parsesSpotifyOutput() {
        let out = ["playing", "spotify:track:1", "Song", "Artist", "Album", "https://i.scdn.co/image/x"].joined(separator: us)
        let t = AppleScriptParser.parse(out, app: .spotify)
        #expect(t == TrackInfo(app: .spotify, id: "spotify:track:1", title: "Song", artist: "Artist",
                               album: "Album", state: .playing, artworkURL: URL(string: "https://i.scdn.co/image/x")))
    }

    @Test func parsesPausedMusicWithoutArtwork() {
        let out = ["paused", "ABC123", "Song", "Artist", "Album", ""].joined(separator: us)
        let t = AppleScriptParser.parse(out, app: .music)
        #expect(t?.state == .paused)
        #expect(t?.artworkURL == nil)
        #expect(t?.app == .music)
    }

    @Test func stoppedOrEmptyIsNil() {
        #expect(AppleScriptParser.parse("stopped", app: .spotify) == nil)
        #expect(AppleScriptParser.parse(["stopped", "x", "y", "z", "w", ""].joined(separator: us), app: .spotify) == nil)
        #expect(AppleScriptParser.parse("", app: .spotify) == nil)
        #expect(AppleScriptParser.parse(["playing", "id", "", "A", "B", ""].joined(separator: us), app: .spotify) == nil)
    }

    @Test func mostRecentPlayingWins() {
        let a = NowPlayingArbiter()
        a.update(track(.spotify, "1", .playing), from: .spotify, at: 1)
        a.update(track(.music, "2", .playing), from: .music, at: 2)
        #expect(a.current?.app == .music)
        a.update(track(.music, "2", .paused), from: .music, at: 3)
        #expect(a.current?.app == .spotify)
    }

    @Test func repeatedPlayingUpdatesDoNotStealFocus() {
        let a = NowPlayingArbiter()
        a.update(track(.spotify, "1", .playing), from: .spotify, at: 1)
        a.update(track(.music, "2", .playing), from: .music, at: 2)
        a.update(track(.spotify, "1", .playing), from: .spotify, at: 3) // poll, still playing
        #expect(a.current?.app == .music)
    }

    @Test func appQuitClearsIt() {
        let a = NowPlayingArbiter()
        a.update(track(.spotify, "1", .playing), from: .spotify, at: 1)
        a.update(nil, from: .spotify, at: 2)
        #expect(a.current == nil)
    }

    @Test func pausedKeptWhenNothingPlays() {
        let a = NowPlayingArbiter()
        a.update(track(.spotify, "1", .paused), from: .spotify, at: 1)
        #expect(a.current?.state == .paused)
    }

    @Test func spotifyCandidates() {
        let t = TrackInfo(app: .spotify, id: "1", title: "S", artist: "A", album: "B", state: .playing,
                          artworkURL: URL(string: "https://i.scdn.co/image/x"))
        #expect(ArtworkResolver.candidates(for: t, hasRawData: false)
                == [.url(URL(string: "https://i.scdn.co/image/x")!), .placeholder])
        var noURL = t
        noURL.artworkURL = nil
        #expect(ArtworkResolver.candidates(for: noURL, hasRawData: false) == [.placeholder])
    }

    @Test func musicCandidatesWithAndWithoutRawData() {
        let t = track(.music, "1", .playing)
        #expect(ArtworkResolver.candidates(for: t, hasRawData: true)
                == [.musicRawData, .itunesLookup(title: "T1", artist: "A"), .placeholder])
        #expect(ArtworkResolver.candidates(for: t, hasRawData: false)
                == [.itunesLookup(title: "T1", artist: "A"), .placeholder])
    }

    @Test func parsesITunesSearch() {
        let json = #"{"resultCount":1,"results":[{"artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg"}]}"#
        #expect(ArtworkResolver.parseITunesSearch(Data(json.utf8))
                == URL(string: "https://is1-ssl.mzstatic.com/image/thumb/a/1000x1000bb.jpg"))
        #expect(ArtworkResolver.parseITunesSearch(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        #expect(ArtworkResolver.parseITunesSearch(Data("garbage".utf8)) == nil)
    }

    @Test func itunesSearchURLIsEncoded() {
        let url = ArtworkResolver.itunesSearchURL(title: "Am I Dreaming", artist: "Metro & Co")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(comps.host == "itunes.apple.com")
        #expect(comps.path == "/search")
        #expect(comps.queryItems?.first { $0.name == "term" }?.value == "Metro & Co Am I Dreaming")
        #expect(comps.queryItems?.first { $0.name == "entity" }?.value == "song")
        #expect(url.absoluteString.contains("%26"))
    }
}

@Suite struct PlaybackFieldTests {
    let us = "\u{1F}"

    @Test func readsPositionAndDuration() {
        let out = ["playing", "id", "Song", "A", "B", "", "12.5", "152000"].joined(separator: us)
        let p = AppleScriptParser.playback(out, app: .spotify)
        #expect(p?.position == 12.5)
        #expect(p?.duration == 152) // Spotify reports milliseconds
        #expect(AppleScriptParser.parse(out, app: .spotify)?.title == "Song") // extra fields don't break parsing
    }

    @Test func musicDurationIsSeconds() {
        let out = ["playing", "id", "Song", "A", "B", "", "3.0", "200.5"].joined(separator: us)
        #expect(AppleScriptParser.playback(out, app: .music)?.duration == 200.5)
    }

    @Test func acceptsCommaDecimals() {
        let out = ["paused", "id", "Song", "A", "B", "", "12,5", "1000"].joined(separator: us)
        #expect(AppleScriptParser.playback(out, app: .spotify)?.position == 12.5)
    }

    @Test func missingFieldsGiveNil() {
        #expect(AppleScriptParser.playback(["playing", "id", "Song", "A", "B", ""].joined(separator: us), app: .spotify) == nil)
    }
}
