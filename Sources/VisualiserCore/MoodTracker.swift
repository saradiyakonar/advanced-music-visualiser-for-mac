import Foundation

public enum AnimationStyle: String, Sendable, CaseIterable {
    case auto, soft, energetic
}

/// A conservative onset-tempo estimate, weighted by measured audio energy.
/// Tempo is an estimate, not a beat grid: expressive or syncopated playing lowers confidence.
public struct MoodTracker: Sendable {
    public var style: AnimationStyle = .auto
    private var beats: [BeatEvent] = []
    private var current: Float = 0.12
    private var target: Float = 0.12
    private var lastUpdate: Double?
    public private(set) var bpm: Double?
    public private(set) var confidence: Float = 0

    public init() {}

    public mutating func reset() {
        let savedStyle = style
        self = MoodTracker()
        style = savedStyle
    }

    public mutating func register(_ beat: BeatEvent) {
        guard lastUpdate.map({ beat.time > $0 }) ?? true else { return }
        if let lastUpdate, beat.time - lastUpdate > 3 { reset() }
        current = eased(at: beat.time)
        lastUpdate = beat.time
        beats.append(beat)
        beats.removeAll { beat.time - $0.time > 10 }
        let intervals = zip(beats, beats.dropFirst()).map { $1.time - $0.time }.filter { (0.28...1.6).contains($0) }
        guard intervals.count >= 3 else { return }
        let median = intervals.sorted()[intervals.count / 2]
        let deviations = intervals.map { abs($0 - median) }.sorted()
        confidence = Float(max(0, 1 - deviations[deviations.count / 2] / median * 3))
            * min(1, Float(intervals.count) / 6)
        let estimate = min(180, 60 / median)
        bpm = estimate
        let tempo = Float(min(1, max(0, (estimate - 78) / 54)))
        let energy = beats.suffix(8).map(\.energy).reduce(0, +) / Float(min(8, beats.count))
        target = (0.025 + 0.975 * tempo * tempo) * (0.08 + 0.92 * energy) * (0.3 + 0.7 * confidence)
    }

    public func intensity(at t: Double) -> Float {
        switch style {
        case .soft: return 0
        case .energetic: return 1
        case .auto:
            let quietTime = max(0, t - (lastUpdate ?? t) - 2.5)
            return eased(at: t) * Float(exp(-quietTime / 2))
        }
    }

    public func tempo(at t: Double) -> Double? {
        guard let lastUpdate, t - lastUpdate < 3, confidence >= 0.5 else { return nil }
        return bpm
    }

    private func eased(at t: Double) -> Float {
        guard let last = lastUpdate else { return current }
        let seconds = target < current ? 1.1 : 3.5
        let k = Float(1 - exp(-max(0, t - last) / seconds))
        return current + (target - current) * k
    }
}
