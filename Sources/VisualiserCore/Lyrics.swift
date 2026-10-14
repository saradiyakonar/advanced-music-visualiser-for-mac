import Foundation

public struct LyricLine: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Parses LRC ("[mm:ss.xx] text") into lines with start and end times.
public enum LRCParser {
    static let lastLineDuration = 5.0

    public static func parse(_ lrc: String) -> [LyricLine] {
        var timed: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let t = seconds(tag) else { break }
                stamps.append(t)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for s in stamps { timed.append((s, text)) }
        }
        timed.sort { $0.0 < $1.0 }
        return timed.enumerated().map { i, item in
            let end = i + 1 < timed.count ? timed[i + 1].0 : item.0 + lastLineDuration
            return LyricLine(start: item.0, end: end, text: item.1)
        }
    }

    /// "mm:ss.xx" → seconds; nil for metadata tags like "ar: Name".
    private static func seconds(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    }
}

/// LRCLIB (https://lrclib.net): free, community-run, line-timed lyrics.
public enum LyricsClient {
    private static var allowed: CharacterSet {
        var a = CharacterSet.urlQueryAllowed
        a.remove(charactersIn: "&+=?")
        return a
    }

    private static func url(_ path: String, _ items: [(String, String)]) -> URL {
        let q = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        return URL(string: "https://lrclib.net\(path)?\(q.joined(separator: "&"))")!
    }

    public static func getURL(title: String, artist: String, album: String, duration: Int?) -> URL {
        var items = [("track_name", title), ("artist_name", artist), ("album_name", album)]
        if let duration { items.append(("duration", String(duration))) }
        return url("/api/get", items)
    }

    /// Looser lookup: drops "(Remastered…)", "[Live]" and " - …" extras from the title.
    public static func searchURL(title: String, artist: String) -> URL {
        url("/api/search", [("track_name", cleanTitle(title)), ("artist_name", artist)])
    }

    static func cleanTitle(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private struct Record: Decodable { let syncedLyrics: String? }

    public static func parseGet(_ data: Data) -> [LyricLine]? {
        guard let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return lines(r.syncedLyrics)
    }

    public static func parseSearch(_ data: Data) -> [LyricLine]? {
        guard let rs = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        return rs.lazy.compactMap { lines($0.syncedLyrics) }.first
    }

    private static func lines(_ synced: String?) -> [LyricLine]? {
        guard let synced, !synced.isEmpty else { return nil }
        let l = LRCParser.parse(synced)
        return l.contains { !$0.text.isEmpty } ? l : nil
    }
}

public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    /// Which line the word belongs to.
    public var line: Int
    /// Position across the whole song; drives style and colour.
    public var index: Int
}

/// Word-by-word timing from line-timed lyrics: each line's words are spread across
/// (part of) the line, weighted by length, so they land roughly as they're sung.
public struct LyricsTimeline: Sendable {
    public let lines: [LyricLine]
    public let words: [TimedWord]
    /// A line's words take at most this long per word, so short lines don't drag.
    static let maxSecondsPerWord = 0.7
    static let lineFill = 0.9

    public init(lines: [LyricLine]) {
        self.lines = lines
        var out: [TimedWord] = []
        for (li, line) in lines.enumerated() {
            let ws = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !ws.isEmpty else { continue }
            let spread = min((line.end - line.start) * Self.lineFill, Double(ws.count) * Self.maxSecondsPerWord)
            let weights = ws.map { Double(max($0.count, 2)) }
            let total = weights.reduce(0, +)
            var acc = 0.0
            for (w, weight) in zip(ws, weights) {
                out.append(TimedWord(text: w, start: line.start + spread * acc / total, line: li, index: out.count))
                acc += weight
            }
        }
        words = out
    }

    /// Up to `limit` most recent words of the line being sung at `position`, oldest first.
    public func visible(at position: Double, limit: Int = 3) -> [TimedWord] {
        guard let li = lines.lastIndex(where: { $0.start <= position }), position < lines[li].end else { return [] }
        return Array(words.filter { $0.line == li && $0.start <= position }.suffix(limit))
    }
}

/// Where the player is in the song, extrapolated between AppleScript polls.
public struct PlaybackClock: Sendable, Equatable {
    public var position: Double
    public var hostTime: Double
    public var playing: Bool

    public init(position: Double, hostTime: Double, playing: Bool) {
        self.position = position
        self.hostTime = hostTime
        self.playing = playing
    }

    /// The position of the sound you hear at `now`; `outputDelay` is how far the speakers lag.
    public func position(at now: Double, outputDelay: Double = 0) -> Double {
        playing ? position + (now - hostTime) - outputDelay : position
    }
}

public struct WordStyle: Equatable, Sendable {
    public enum Weight: Sendable, Hashable { case heavy, bold, semibold, regular }
    public var weight: Weight
    public var italic: Bool
    /// Solid colour block behind white text.
    public var block: Bool
    /// SF Symbol name shown next to the word.
    public var icon: String?
    /// Emoji shown next to the word (only when there's no icon).
    public var emoji: String?
}

/// Per-word look for the lyrics screen (after the reference video): mixed weights,
/// some italic, some in a colour block, icons for common words.
public enum WordStyler {
    /// Seconds before the palette shifts one step.
    public static let colourPeriod = 4.0

    static let icons: [String: String] = [
        "see": "eye.fill", "look": "eye.fill", "watch": "eye.fill", "eyes": "eye.fill", "saw": "eye.fill",
        "tell": "bubble.left.fill", "telling": "bubble.left.fill", "talk": "bubble.left.fill",
        "talking": "bubble.left.fill", "say": "bubble.left.fill", "said": "bubble.left.fill",
        "ball": "basketball.fill", "ballin": "basketball.fill", "balling": "basketball.fill",
        "number": "number", "phone": "phone.fill", "call": "phone.fill",
        "love": "heart.fill", "heart": "heart.fill",
        "money": "dollarsign.circle.fill", "cash": "dollarsign.circle.fill", "racks": "dollarsign.circle.fill",
        "fire": "flame.fill", "lit": "flame.fill", "burn": "flame.fill",
        "star": "star.fill", "stars": "star.fill",
        "night": "moon.fill", "moon": "moon.fill", "sun": "sun.max.fill",
        "car": "car.fill", "drive": "car.fill", "ride": "car.fill",
        "music": "music.note", "song": "music.note",
        "time": "clock.fill", "chance": "dice.fill", "chances": "dice.fill",
        "wind": "wind", "blew": "wind", "blow": "wind",
        "dream": "sparkles", "dreaming": "sparkles", "dreams": "sparkles",
        "cry": "drop.fill", "tears": "drop.fill", "rain": "cloud.rain.fill",
        "king": "crown.fill", "queen": "crown.fill", "crown": "crown.fill",
        "world": "globe.americas.fill", "home": "house.fill", "house": "house.fill",
    ]

    /// Emoji for common lyric words. Built from pairs so a repeated word can't crash at launch.
    public static let emoji: [String: String] = Dictionary([
        ("baby", "👶"), ("kiss", "💋"), ("party", "🥳"), ("dance", "💃"), ("dancing", "💃"),
        ("drink", "🍸"), ("drinks", "🍸"), ("drunk", "🥴"), ("high", "🚀"), ("fly", "🕊️"),
        ("flying", "✈️"), ("plane", "✈️"), ("rich", "💰"), ("diamond", "💎"), ("diamonds", "💎"),
        ("ice", "🧊"), ("cold", "🥶"), ("hot", "🥵"), ("crazy", "🤪"), ("smile", "😊"),
        ("happy", "😄"), ("sad", "😢"), ("angry", "😤"), ("mad", "😤"), ("devil", "😈"),
        ("angel", "😇"), ("god", "🙏"), ("pray", "🙏"), ("lord", "🙏"), ("ghost", "👻"),
        ("dead", "💀"), ("die", "💀"), ("bang", "💥"), ("boom", "💥"), ("win", "🏆"),
        ("winning", "🏆"), ("gold", "🥇"), ("rose", "🌹"), ("roses", "🌹"), ("flower", "🌸"),
        ("ocean", "🌊"), ("sea", "🌊"), ("wave", "🌊"), ("waves", "🌊"), ("beach", "🏖️"),
        ("summer", "☀️"), ("snow", "❄️"), ("winter", "❄️"), ("storm", "⛈️"), ("lightning", "⚡"),
        ("electric", "⚡"), ("rock", "🤘"), ("hug", "🫂"), ("friends", "🫂"), ("hands", "🙌"),
        ("clap", "👏"), ("goodbye", "👋"), ("bye", "👋"), ("hello", "👋"), ("alone", "🥀"),
        ("lonely", "🥀"), ("broken", "💔"), ("heartbreak", "💔"), ("sleep", "😴"), ("tired", "😴"),
        ("wake", "⏰"), ("late", "⏰"), ("mind", "🧠"), ("think", "🤔"), ("thinking", "🤔"),
        ("secret", "🤫"), ("quiet", "🤫"), ("loud", "📢"), ("scream", "😱"), ("run", "🏃"),
        ("running", "🏃"), ("road", "🛣️"), ("city", "🌆"), ("food", "🍔"), ("eat", "🍽️"),
        ("cake", "🎂"), ("birthday", "🎂"), ("smoke", "💨"), ("smoking", "💨"), ("sky", "🌌"),
        ("heaven", "☁️"), ("magic", "🪄"), ("game", "🎮"), ("text", "📱"), ("camera", "📸"),
        ("photo", "📸"), ("picture", "📸"), ("door", "🚪"), ("key", "🔑"), ("lock", "🔒"),
        ("free", "🕊️"), ("freedom", "🕊️"), ("cool", "😎"), ("shine", "✨"), ("shining", "✨"),
        ("gone", "💨"), ("forever", "♾️"), ("ring", "💍"), ("married", "💍"), ("rain", "🌧️"),
    ], uniquingKeysWith: { first, _ in first })

    public static func style(for word: String, index: Int) -> WordStyle {
        let h = UInt32(truncatingIfNeeded: (index &+ 1) &* 2_654_435_761)
        let weights: [WordStyle.Weight] = [.heavy, .bold, .semibold, .regular]
        let key = word.lowercased().filter(\.isLetter)
        let hasScene = LyricScenePlanner.theme(for: word) != nil
        let icon = hasScene ? nil : icons[key]
        return WordStyle(weight: weights[Int((h >> 7) % 4)], italic: (h >> 13) % 5 == 0,
                         block: (h >> 3) % 10 < 3, icon: icon, emoji: icon == nil && !hasScene ? emoji[key] : nil)
    }

    public static func colour(forWordIndex i: Int, time: Double, palette: [RGB]) -> RGB {
        let p = palette.isEmpty ? PaletteExtractor.fallback : palette
        let shift = Int((time / colourPeriod).rounded(.down))
        return p[((i + shift) % p.count + p.count) % p.count]
    }
}
