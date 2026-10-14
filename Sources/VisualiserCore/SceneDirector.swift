import Foundation

public enum LyricTheme: Int, CaseIterable, Sendable {
    case storm, fire, water, stars, warmth, drift, snow, flowers, rain, celebration
}

public struct SceneCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var theme: LyricTheme
}

/// Local, English phrase rules: predictable cues without network generation or invented word timing.
public enum LyricScenePlanner {
    public static func theme(for text: String) -> LyricTheme? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let phrase = words.joined(separator: " ")
        let tokens = Set(words)
        if ["put out the fire", "fire is out", "no more fire", "burned out", "burnt out"].contains(where: phrase.contains) { return .drift }
        let families: [(LyricTheme, Set<String>)] = [
            (.storm, ["lightning", "thunder", "storm", "electric"]),
            (.fire, ["fire", "flame", "flames", "burn", "burning", "embers"]),
            (.water, ["ocean", "sea", "waves", "wave", "drown", "drowning", "river"]),
            (.stars, ["stars", "star", "sky", "fly", "flying", "galaxy", "constellation"]),
            (.drift, ["lonely", "alone", "goodbye", "gone", "heartbreak", "broken"]),
            (.warmth, ["love", "hearts", "heart", "kiss", "kisses", "together"]),
            (.snow, ["snow", "snowflakes", "winter", "frozen", "ice"]),
            (.flowers, ["flower", "flowers", "rose", "roses", "bloom", "blossom"]),
            (.rain, ["rain", "raining", "tears", "cry", "crying"]),
            (.celebration, ["party", "dance", "dancing", "boom", "bang", "explode", "explosion", "celebrate"])
        ]
        return families.first { !$0.1.isDisjoint(with: tokens) }?.0
    }

    public static func plan(_ timeline: LyricsTimeline) -> [SceneCue] {
        var cues: [SceneCue] = []
        for line in timeline.lines.sorted(by: { $0.start < $1.start }) {
            guard line.start.isFinite, line.end.isFinite, line.end > line.start,
                  let theme = theme(for: line.text) else { continue }
            // A phrase gets room to breathe. Repeated chorus imagery keeps its visual identity.
            if let last = cues.last, line.start - last.start < 4 { continue }
            if !cues.isEmpty { cues[cues.count - 1].end = min(cues[cues.count - 1].end, line.start) }
            cues.append(SceneCue(start: line.start, end: min(line.start + 10, max(line.start + 4, line.end)), theme: theme))
        }
        return cues
    }
}

public struct SceneDirection: Sendable {
    public var accent: Float = 0
    public var accentProgress: Float = 1
    public var accentSerial: Int = 0
    public var weights: [Float] = Array(repeating: 0, count: LyricTheme.allCases.count)
}

/// Uses playback time for lyric selection and host time for beat-aligned entrances.
/// A seek immediately clears the old cue; no lyrics simply leaves the audio visuals running.
public struct SceneDirector: Sendable {
    private var cues: [SceneCue] = []
    private var selected: SceneCue?
    private var pendingSince: Double?
    private var activeSince: Double?
    private var accentTime: Double?
    private var accentSerial = 0
    private var position: Double = 0
    private var previousPosition: Double?
    private var previousHost: Double?
    private var weights: [Float] = Array(repeating: 0, count: LyricTheme.allCases.count)

    public init() {}

    public mutating func load(_ timeline: LyricsTimeline?) {
        self = SceneDirector()
        cues = timeline.map(LyricScenePlanner.plan) ?? []
    }

    public mutating func update(position: Double, hostTime: Double) {
        guard position.isFinite, hostTime.isFinite else { return }
        if let old = previousPosition, let host = previousHost,
           abs((position - old) - (hostTime - host)) > 1.2 {
            selected = nil; pendingSince = nil; activeSince = nil; accentTime = nil
            weights = Array(repeating: 0, count: LyricTheme.allCases.count)
        }
        self.position = position
        previousPosition = position; previousHost = hostTime
        let cue = cues.last { $0.start <= position && position < $0.end }
        if cue != selected {
            selected = cue
            pendingSince = cue == nil ? nil : hostTime
            activeSince = nil; accentTime = nil
        }
    }

    public mutating func register(_ beat: BeatEvent) {
        guard selected != nil, beat.strength >= 0.5, beat.energy > 0.15 else { return }
        if let pending = pendingSince, beat.time >= pending {
            activeSince = beat.time; pendingSince = nil
            accentTime = beat.time; accentSerial += 1
        } else if let active = activeSince, beat.time >= active,
                  beat.time - (accentTime ?? -.infinity) >= 1.4 {
            accentTime = beat.time; accentSerial += 1
        }
    }

    public mutating func frame(at time: Double, dt: Double, paused: Bool) -> SceneDirection {
        guard !paused else { return SceneDirection() }
        if let pending = pendingSince, time - pending >= 0.45 {
            activeSince = pending + 0.45; pendingSince = nil
            accentTime = activeSince; accentSerial += 1
        }
        var target = Array(repeating: Float(0), count: LyricTheme.allCases.count)
        if let cue = selected, let start = activeSince, time >= start {
            // Fade out before the phrase expires. A stopped playback clock cannot hold a cue forever.
            let remaining = min(cue.end - position, 10 - (time - start))
            target[cue.theme.rawValue] = Float(min(1, max(0, remaining / 1.2)))
        }
        for i in weights.indices {
            let blend = Float(1 - exp(-min(0.1, max(0, dt)) / (target[i] > weights[i] ? 0.10 : 0.35)))
            weights[i] += (target[i] - weights[i]) * blend
        }
        let age = accentTime.map { time - $0 } ?? -1
        let progress = Float(min(1, max(0, age / 1.4)))
        let accent: Float = age >= 0 && age < 1.4 ? Float(min(1, age / 0.045)) * (1 - progress) : 0
        return SceneDirection(accent: accent, accentProgress: progress, accentSerial: accentSerial, weights: weights)
    }
}
