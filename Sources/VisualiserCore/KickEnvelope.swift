import Foundation

/// A detected beat, timestamped on the host clock (seconds).
public struct BeatEvent: Sendable, Equatable {
    public var time: Double
    /// Onset strength relative to recent peaks, 0...1.
    public var strength: Float
    public var isBigHit: Bool
    /// Absolute audio energy; unlike onset strength this is not normalized to recent peaks.
    public var energy: Float

    public init(time: Double, strength: Float, isBigHit: Bool, energy: Float = 1) {
        self.time = time
        self.strength = strength
        self.isBigHit = isBigHit
        self.energy = min(1, max(0, energy))
    }
}

/// Everything the renderer needs for one frame.
public struct VisualFrame: Equatable, Sendable {
    public var coverScale: Float
    public var glowScale: Float
    public var glowOpacity: Float
    public var frameOpacity: Float
    public var glitchAmount: Float
    public var slicesVisible: Bool
    /// Increments on every beat; seeds glitch slice positions.
    public var beatSerial: Int
    /// Cover rotation in radians; alternates direction beat to beat.
    public var tilt: Float
    /// Position of the edge frame's colour flow (in palette cycles). Always increasing:
    /// time moves it slowly and each beat pushes it along smoothly.
    public var colourFlow: Double
    public var impact: Float = 0
    public var impactProgress: Float = 0
    public var rhythmDrive: Float = 0
    public var backgroundPulse: Float = 0
    public var drop: Float = 0
    public var dropProgress: Float = 0
    public var buildup: Float = 0
}

/// Turns beat events (and optional live band levels) into per-frame animation values.
/// Base formulas come from docs/mockups/2-mix-a-b.html (option 1: glitch on big hits only).
public struct VisualAnimator: Sendable {
    /// Seconds to rise to the peak of a beat; an eased rise reads smoother than a jump.
    public static let attack = 0.04
    static let flowPerSecond = 0.03
    static let flowPerBeat = 0.12
    static let maxTilt: Float = 0.025

    public let beatDecay: Double
    /// 0 = soft (slow songs: gentler, longer pulse, no glitch), 1 = energetic. See MoodTracker.
    public var intensity: Float = 1
    public var tempo: Double?
    private var lastBeat: BeatEvent?
    private var serial = 0
    private var lastImpact: BeatEvent?
    private var flowBase = 0.0
    private var recentBeats: [BeatEvent] = []
    private var fastInterval: Double?
    private var drive: Float = 0
    private var lastDrop: BeatEvent?


    public init(beatDecay: Double = 0.6) {
        self.beatDecay = beatDecay
    }

    public mutating func register(_ e: BeatEvent) {
        guard e.time.isFinite, lastBeat.map({ e.time > $0.time }) ?? true else { return }
        if let previous = lastBeat, e.time - previous.time > 3 {
            recentBeats.removeAll()
            fastInterval = nil
            drive = 0
        }
        let intervals = zip(recentBeats, recentBeats.dropFirst()).map { $1.time - $0.time }
        let baseline = intervals.isEmpty ? 0 : intervals.sorted()[intervals.count / 2]
        let energy = recentBeats.isEmpty ? e.energy : recentBeats.map(\.energy).reduce(0, +) / Float(recentBeats.count)
        if let previous = lastBeat {
            let gap = e.time - previous.time
            if (0.25...1.6).contains(gap) {
                fastInterval = gap * 0.65 + (fastInterval ?? gap) * 0.35
                let quickening = baseline > 0 && gap < baseline * 0.78
                    && (intervals.last.map { $0 < baseline * 0.78 } ?? false)
                let surge = recentBeats.count >= 4 && e.energy > max(0.35, energy * 1.7)
                if (quickening || surge), e.energy > 0.25, e.strength > 0.5,
                   e.time - (lastDrop?.time ?? -.infinity) > 2.5 {
                    lastDrop = e
                }
                let speed = Float(min(1, max(0, (0.75 - (fastInterval ?? gap)) / 0.42)))
                drive = speed * e.energy
            } else { drive = 0; fastInterval = nil }
        }
        recentBeats.append(e)
        if recentBeats.count > 12 { recentBeats.removeFirst() }
        if let b = lastBeat { flowBase += Self.flowPerBeat * progress(since: b, at: e.time) }
        // Let each wave finish; dense kick patterns should not become a strobe.
        if e.isBigHit, e.strength >= 0.65,
           e.time - (lastImpact?.time ?? -.infinity) >= 1.4 {
            lastImpact = e
        }
        lastBeat = e
        serial += 1
    }

    public func frame(at t: Double, paused: Bool, levels: BandLevels? = nil) -> VisualFrame {
        let flow = Self.flowPerSecond * t + flowBase + (lastBeat.map { Self.flowPerBeat * progress(since: $0, at: t) } ?? 0)

        if paused {
            let breath = Float(sin(2 * Double.pi * t / 4))
            return VisualFrame(coverScale: 1, glowScale: 1.2, glowOpacity: 0.25 + 0.1 * breath, frameOpacity: 0.2,
                               glitchAmount: 0, slicesVisible: false, beatSerial: serial, tilt: 0, colourFlow: flow)
        }

        var env: Float = 0
        var big = false
        var strength: Float = 0
        if let b = lastBeat {
            env = envelope(t - b.time)
            big = b.isBigHit
            strength = min(1, max(0, b.strength)) * (0.2 + 0.8 * b.energy)
        }
        let baseIntensity = min(max(intensity, 0), 1)
        let age = max(0, t - (lastBeat?.time ?? t))
        let rhythm = drive * Float(exp(-max(0, age - 0.3) / 0.7)) * (baseIntensity > 0 ? 1 : 0)
        let dropAge = lastDrop.map { t - $0.time } ?? -1
        let drop: Float = dropAge >= 0 && dropAge < 2.4 && baseIntensity > 0
            ? Float(min(1, dropAge / 0.06) * pow(1 - dropAge / 2.4, 2)) * (lastDrop?.energy ?? 0) : 0
        let recentEnergy = recentBeats.suffix(3).map(\.energy)
        let earlierEnergy = recentBeats.dropLast(3).suffix(3).map(\.energy)
        let rising: Float = earlierEnergy.count == 3
            ? max(0, recentEnergy.reduce(0, +) / 3 - earlierEnergy.reduce(0, +) / 3) : 0
        let buildup = min(1, rising * 2.5) * Float(exp(-age / 1.2)) * (1 - drop) * (baseIntensity > 0 ? 1 : 0)
        let i = max(baseIntensity, max(rhythm * 0.85, drop))
        let kick = env * (big ? 1 : 0.6) * strength * (0.035 + 0.965 * i * i)

        var glitch: Float = (big && i > 0.55) ? env : 0
        if glitch < 0.08 { glitch = 0 }

        let sensitivity: Float = 0.035 + 0.965 * i * i
        let l = levels ?? BandLevels(bass: 0, mid: 0, treble: 0)
        let impactAge = lastImpact.map { t - $0.time } ?? -1
        let impactProgress = Float(min(1, max(0, impactAge / 1.15)))
        let impact: Float = impactAge >= 0 && impactAge < 1.15
            ? Float(min(1, impactAge / 0.055)) * pow(1 - impactProgress, 2) * (lastImpact?.strength ?? 0) * (lastImpact?.energy ?? 0) * i * i : 0
        let direction: Float = serial % 2 == 1 ? 1 : -1

        return VisualFrame(
            coverScale: 1 + 0.18 * kick + 0.035 * l.bass * sensitivity,
            glowScale: 1.2 + 1.4 * kick + 0.3 * l.bass * sensitivity,
            glowOpacity: 0.35 + 0.6 * kick + 0.2 * l.mid * sensitivity,
            frameOpacity: min(1, 0.25 + 0.75 * kick + 0.15 * l.treble * sensitivity),
            glitchAmount: glitch,
            slicesVisible: big && glitch > 0.35,
            beatSerial: serial,
            tilt: direction * Self.maxTilt * kick * i,
            colourFlow: flow, impact: impact, impactProgress: impactProgress,
            rhythmDrive: rhythm, backgroundPulse: min(1, kick * (1 + rhythm * 0.65)), drop: drop, dropProgress: Float(min(1, max(0, dropAge / 2.4))), buildup: buildup
        )
    }

    /// Soft songs let each pulse linger up to ~1.9× longer.
    private var decay: Double {
        if let fastInterval, drive > 0.15 { return max(0.18, fastInterval * 0.72) }
        if let tempo, tempo.isFinite, tempo > 0 { return min(1.2, max(0.22, 60 / tempo * 0.85)) }
        return beatDecay * (1 + 0.9 * Double(1 - min(max(intensity, 0), 1)))
    }

    /// 0 → 1 eased rise over `attack`, then (1 − p)³ decay over `decay`.
    private func envelope(_ dt: Double) -> Float {
        guard dt >= 0 else { return 0 }
        if dt < Self.attack {
            let x = dt / Self.attack
            return Float(1 - (1 - x) * (1 - x))
        }
        let p = min((dt - Self.attack) / decay, 1)
        return Float(pow(1 - p, 3))
    }

    /// Smoothstep 0 → 1 across the whole beat (attack + decay); drives the colour push.
    private func progress(since b: BeatEvent, at t: Double) -> Double {
        let x = min(max((t - b.time) / (Self.attack + decay), 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// Smooths band levels for display: rises quickly, falls slowly.
public struct LevelSmoother: Sendable {
    public var attackTime = 0.02
    public var releaseTime = 0.25
    private(set) var value = BandLevels(bass: 0, mid: 0, treble: 0)

    public init() {}

    public mutating func update(_ target: BandLevels, dt: Double) -> BandLevels {
        func step(_ v: Float, _ x: Float) -> Float {
            let tau = x > v ? attackTime : releaseTime
            return v + (x - v) * Float(1 - exp(-dt / tau))
        }
        value = BandLevels(bass: step(value.bass, target.bass), mid: step(value.mid, target.mid),
                           treble: step(value.treble, target.treble))
        return value
    }
}
