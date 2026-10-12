import Foundation

public enum AnimationStyle: String, Sendable, CaseIterable {
    case auto, soft, energetic
}

/// Guesses how energetic the song is from its beat (Spotify doesn't expose genre):
/// slow songs get a soft pulse, fast ones the punchy one. Changes ease in over seconds.
public struct MoodTracker: Sendable {
    public var style: AnimationStyle = .auto

    /// BPM at or below which the animation is fully soft, and at or above which fully energetic.
    static let softBPM = 88.0
    static let energeticBPM = 112.0
    static let window = 10.0     // seconds of beats used for the tempo estimate
    static let easing = 3.0      // seconds; time constant for moving between moods

    private var beats: [Double] = []
    private var current: Float = 1
    private var target: Float = 1
    private var lastUpdate: Double?

    public init() {}

    /// Median-interval tempo of the last few seconds, if there's enough to tell.
    public private(set) var bpm: Double?

    public mutating func register(_ beat: BeatEvent) {
        current = eased(at: beat.time)
        lastUpdate = beat.time

        beats.append(beat.time)
        beats.removeAll { beat.time - $0 > Self.window }
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }.filter { (0.25...1.5).contains($0) }
        guard intervals.count >= 4 else { return }
        let median = intervals.sorted()[intervals.count / 2]
        let tempo = 60 / median
        bpm = tempo
        let x = (tempo - Self.softBPM) / (Self.energeticBPM - Self.softBPM)
        target = Float(min(max(x, 0), 1))
    }

    /// 0 = soft, 1 = energetic.
    public func intensity(at t: Double) -> Float {
        switch style {
        case .soft: return 0
        case .energetic: return 1
        case .auto: return eased(at: t)
        }
    }

    private func eased(at t: Double) -> Float {
        guard let last = lastUpdate else { return current }
        let k = Float(1 - exp(-max(0, t - last) / Self.easing))
        return current + (target - current) * k
    }
}
