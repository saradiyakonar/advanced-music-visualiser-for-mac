import Testing
@testable import VisualiserCore

@Suite struct SceneDirectorTests {
    @Test func matchesPhrasesAndWholeWords() {
        #expect(LyricScenePlanner.theme(for: "LIGHTNING, across the sky!") == .storm)
        #expect(LyricScenePlanner.theme(for: "put out the fire") == .drift)
        #expect(LyricScenePlanner.theme(for: "set the night on fire") == .fire)
        #expect(LyricScenePlanner.theme(for: "a sweetheart's seawall") == nil)
        #expect(LyricScenePlanner.theme(for: "waves") == .water)
        #expect(LyricScenePlanner.theme(for: "stars") == .stars)
        #expect(LyricScenePlanner.theme(for: "love") == .warmth)
        #expect(LyricScenePlanner.theme(for: "goodbye") == .drift)
    }

    @Test func spacesCuesAndKeepsChorusIdentity() {
        let timeline = LyricsTimeline(lines: [
            LyricLine(start: 0, end: 2, text: "lightning"),
            LyricLine(start: 2, end: 4, text: "fire"),
            LyricLine(start: 8, end: 12, text: "lightning")])
        let cues = LyricScenePlanner.plan(timeline)
        #expect(cues.count == 2)
        #expect(cues[0].theme == cues[1].theme)
    }

    @Test func waitsForBeatThenFadesAndResetsOnSeek() {
        var director = SceneDirector()
        director.load(LyricsTimeline(lines: [LyricLine(start: 1, end: 6, text: "lightning")]))
        director.update(position: 1, hostTime: 10)
        #expect(director.frame(at: 10.1, dt: 0.1, paused: false).weights[0] == 0)
        director.register(BeatEvent(time: 10.2, strength: 1, isBigHit: false))
        #expect(director.frame(at: 10.3, dt: 0.1, paused: false).weights[0] > 0)
        #expect(director.frame(at: 10.4, dt: 0.1, paused: true).weights.allSatisfy { $0 == 0 })
        director.update(position: 30, hostTime: 10.5)
        #expect(director.frame(at: 10.6, dt: 0.1, paused: false).weights.allSatisfy { $0 == 0 })
        director.load(nil)
        #expect(director.frame(at: 11, dt: 0.1, paused: false).weights.allSatisfy { $0 == 0 })
    }

    @Test func sparseAudioStillShowsCueAndExpires() {
        var director = SceneDirector()
        director.load(LyricsTimeline(lines: [LyricLine(start: 0, end: 4, text: "ocean")]))
        director.update(position: 0, hostTime: 0)
        #expect(director.frame(at: 0.5, dt: 0.1, paused: false).weights[2] > 0)
        for n in 1...100 { _ = director.frame(at: 11 + Double(n) * 0.1, dt: 0.1, paused: false) }
        #expect(director.frame(at: 22, dt: 0.1, paused: false).weights[2] < 0.001)
    }
}

@Suite struct SceneAccentTests {
    @Test func accentsHaveCooldownAndClearOnSeek() {
        var director = SceneDirector()
        director.load(LyricsTimeline(lines: [LyricLine(start: 0, end: 10, text: "love")]))
        director.update(position: 0, hostTime: 0)
        director.register(BeatEvent(time: 0, strength: 1, isBigHit: true))
        let first = director.frame(at: 0.1, dt: 0.1, paused: false)
        #expect(first.accent > 0.8)
        director.register(BeatEvent(time: 0.3, strength: 1, isBigHit: true))
        #expect(director.frame(at: 0.4, dt: 0.1, paused: false).accentSerial == first.accentSerial)
        director.register(BeatEvent(time: 1.5, strength: 1, isBigHit: true))
        #expect(director.frame(at: 1.6, dt: 0.1, paused: false).accentSerial == first.accentSerial + 1)
        #expect(director.frame(at: 1.6, dt: 0.1, paused: true).accent == 0)
        director.update(position: 30, hostTime: 1.7)
        #expect(director.frame(at: 1.8, dt: 0.1, paused: false).accent == 0)
    }
    @Test func expandedImageryUsesScenesRatherThanEmoji() {
        #expect(LyricScenePlanner.theme(for: "hearts") == .warmth)
        #expect(LyricScenePlanner.theme(for: "winter snow") == .snow)
        #expect(LyricScenePlanner.theme(for: "roses bloom") == .flowers)
        #expect(LyricScenePlanner.theme(for: "tears in the rain") == .rain)
        #expect(LyricScenePlanner.theme(for: "dance party") == .celebration)
        #expect(WordStyler.style(for: "lightning", index: 0).emoji == nil)
        #expect(WordStyler.style(for: "love", index: 0).icon == nil)
    }
}
