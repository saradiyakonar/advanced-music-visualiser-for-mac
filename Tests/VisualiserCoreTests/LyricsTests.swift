import Foundation
import Testing
@testable import VisualiserCore

@Suite struct LRCParserTests {
    @Test func parsesTimedLines() {
        let lines = LRCParser.parse("[00:01.02] Hello world\n[00:03.36]\n[00:05.00]Next one")
        #expect(lines.map(\.text) == ["Hello world", "", "Next one"])
        #expect(abs(lines[0].start - 1.02) < 1e-9)
        #expect(abs(lines[0].end - 3.36) < 1e-9)
        #expect(abs(lines[2].end - 10.0) < 1e-9) // last line lasts 5 s
    }

    @Test func expandsRepeatedTimestamps() {
        let lines = LRCParser.parse("[00:20.00][00:10.00]Chorus\n[00:15.00]Verse")
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lines.map(\.start) == [10, 15, 20])
    }

    @Test func ignoresMetadataAndJunk() {
        let lines = LRCParser.parse("[ar: Someone]\n[ti: Title]\nnot a lyric\n[01:02.5]Late")
        #expect(lines.count == 1)
        #expect(abs(lines[0].start - 62.5) < 1e-9)
    }
}

@Suite struct LyricsClientTests {
    @Test func parsesGetResponse() {
        let json = #"{"id":1,"instrumental":false,"syncedLyrics":"[00:01.00]One two\n[00:02.00]Three"}"#
        let lines = LyricsClient.parseGet(Data(json.utf8))
        #expect(lines?.map(\.text) == ["One two", "Three"])
    }

    @Test func missingSyncedLyricsIsNil() {
        #expect(LyricsClient.parseGet(Data(#"{"syncedLyrics":null,"plainLyrics":"x"}"#.utf8)) == nil)
        #expect(LyricsClient.parseGet(Data(#"{"instrumental":true,"syncedLyrics":null}"#.utf8)) == nil)
        #expect(LyricsClient.parseGet(Data("<html>".utf8)) == nil)
    }

    @Test func searchPicksFirstSyncedResult() {
        let json = #"[{"syncedLyrics":null},{"syncedLyrics":"[00:03.00]Found"}]"#
        #expect(LyricsClient.parseSearch(Data(json.utf8))?.first?.text == "Found")
        #expect(LyricsClient.parseSearch(Data("[]".utf8)) == nil)
    }

    @Test func buildsURLs() {
        let get = LyricsClient.getURL(title: "Am I Dreaming", artist: "Metro & Co", album: "Album", duration: 152)
        let c = URLComponents(url: get, resolvingAgainstBaseURL: false)!
        #expect(c.host == "lrclib.net")
        #expect(c.path == "/api/get")
        #expect(c.queryItems?.first { $0.name == "artist_name" }?.value == "Metro & Co")
        #expect(c.queryItems?.first { $0.name == "duration" }?.value == "152")
        #expect(get.absoluteString.contains("%26"))
        let search = LyricsClient.searchURL(title: "Song (Remastered 2011)", artist: "A")
        let sc = URLComponents(url: search, resolvingAgainstBaseURL: false)!
        #expect(sc.path == "/api/search")
        #expect(sc.queryItems?.first { $0.name == "track_name" }?.value == "Song") // bracketed extras dropped
    }
}

@Suite struct LyricsTimelineTests {
    let lines = [
        LyricLine(start: 1, end: 3, text: "Hello world"),
        LyricLine(start: 3, end: 5, text: ""),
        LyricLine(start: 5, end: 9, text: "one two three four five"),
    ]

    @Test func firstWordStartsWithItsLine() {
        let t = LyricsTimeline(lines: lines)
        #expect(t.words.first?.text == "Hello")
        #expect(t.words.first?.start == 1)
    }

    @Test func wordsAreSpreadInOrderWithinTheLine() {
        let t = LyricsTimeline(lines: lines)
        let line3 = t.words.filter { $0.line == 2 }
        #expect(line3.count == 5)
        for (a, b) in zip(line3, line3.dropFirst()) { #expect(a.start < b.start) }
        #expect(line3.last!.start < 9)
    }

    @Test func visibleShowsLastThreeOfCurrentLine() {
        let t = LyricsTimeline(lines: lines)
        #expect(t.visible(at: 0.5).isEmpty)                 // before lyrics
        #expect(t.visible(at: 1.01).map(\.text) == ["Hello"])
        #expect(t.visible(at: 2.9).map(\.text) == ["Hello", "world"])
        #expect(t.visible(at: 4).isEmpty)                    // blank line clears
        #expect(t.visible(at: 8.9).map(\.text) == ["three", "four", "five"])
    }

    @Test func wordIndicesAreStableAndGlobal() {
        let t = LyricsTimeline(lines: lines)
        #expect(t.words.map(\.index) == Array(0..<t.words.count))
    }
}

@Suite struct PlaybackClockTests {
    @Test func extrapolatesWhilePlaying() {
        let c = PlaybackClock(position: 10, hostTime: 100, playing: true)
        #expect(c.position(at: 102.5) == 12.5)
    }

    @Test func holdsWhilePaused() {
        let c = PlaybackClock(position: 10, hostTime: 100, playing: false)
        #expect(c.position(at: 105) == 10)
    }

    @Test func outputDelayShiftsWhatYouHear() {
        let c = PlaybackClock(position: 10, hostTime: 100, playing: true)
        #expect(abs(c.position(at: 101, outputDelay: 0.2) - 10.8) < 1e-9)
    }
}

@Suite struct WordStylerTests {
    @Test func iconsForCommonWords() {
        #expect(WordStyler.style(for: "see", index: 0).icon == "eye.fill")
        #expect(WordStyler.style(for: "See,", index: 0).icon == "eye.fill")
        #expect(WordStyler.style(for: "telling", index: 3).icon == "bubble.left.fill")
        #expect(WordStyler.style(for: "ballin'", index: 3).icon == "basketball.fill")
        #expect(WordStyler.style(for: "the", index: 3).icon == nil)
    }

    @Test func styleIsDeterministic() {
        #expect(WordStyler.style(for: "night", index: 7) == WordStyler.style(for: "night", index: 7))
    }

    @Test func blocksAreAMinority() {
        let blocks = (0..<200).filter { WordStyler.style(for: "word", index: $0).block }.count
        #expect(blocks >= 30 && blocks <= 90)
    }

    @Test func weightsVary() {
        let weights = Set((0..<50).map { WordStyler.style(for: "word", index: $0).weight })
        #expect(weights.count >= 3)
        #expect((0..<50).contains { WordStyler.style(for: "word", index: $0).italic })
    }

    @Test func coloursCycleThroughPaletteOverTime() {
        let pal = [RGB(r: 1, g: 0, b: 0), RGB(r: 0, g: 1, b: 0), RGB(r: 0, g: 0, b: 1)]
        #expect(WordStyler.colour(forWordIndex: 0, time: 0, palette: pal) == pal[0])
        #expect(WordStyler.colour(forWordIndex: 1, time: 0, palette: pal) == pal[1])
        #expect(WordStyler.colour(forWordIndex: 0, time: WordStyler.colourPeriod, palette: pal) == pal[1])
        #expect(WordStyler.colour(forWordIndex: 0, time: 0, palette: []) == PaletteExtractor.fallback[0])
    }
}

@Suite struct EmojiTests {
    @Test func commonWordsGetEmoji() {
        #expect(WordStyler.style(for: "party", index: 0).emoji == "🥳")
        #expect(WordStyler.style(for: "Diamonds,", index: 1).emoji == "💎")
        #expect(WordStyler.style(for: "goodbye!", index: 2).emoji == "👋")
        #expect(WordStyler.style(for: "the", index: 3).emoji == nil)
    }

    @Test func aWordGetsAnIconOrAnEmojiNotBoth() {
        for word in WordStyler.emoji.keys {
            let s = WordStyler.style(for: word, index: 0)
            #expect(!(s.icon != nil && s.emoji != nil), "\(word)")
        }
    }

    @Test func thereAreLotsOfThem() {
        #expect(WordStyler.emoji.count >= 70)
    }
}
