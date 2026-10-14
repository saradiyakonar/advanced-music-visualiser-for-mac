import Foundation

public struct LaserFrame: Sendable {
    public var sweep: Float = 0
    public var spread: Float = 0.3
    public var cross: Float = 0
    public var curtain: Float = 0
    public init(sweep: Float = 0, spread: Float = 0.3, cross: Float = 0, curtain: Float = 0) {
        self.sweep = sweep; self.spread = spread; self.cross = cross; self.curtain = curtain
    }
}

/// Beat-triggered lighting cues, rather than a free-running sine-wave animation.
public struct LaserChoreographer: Sendable {
    private var previous = LaserFrame()
    private var target = LaserFrame()
    private var lastBeat: Double?
    private var count = 0
    public init() {}

    public mutating func register(_ beat: BeatEvent) {
        guard beat.time.isFinite, lastBeat.map({ beat.time > $0 }) ?? true else { return }
        if let lastBeat, beat.time - lastBeat > 3 { self = LaserChoreographer() }
        previous = frame(at: beat.time)
        lastBeat = beat.time
        count += 1
        let energy = min(1, max(0, beat.energy * beat.strength))
        let direction: Float = count % 2 == 0 ? 1 : -1
        let pattern = ((count - 1) / 8) % 3
        target = LaserFrame(sweep: direction * (0.12 + energy * 0.48),
                            spread: 0.2 + energy * (beat.isBigHit ? 0.95 : 0.48),
                            cross: pattern == 1 ? 1 : 0, curtain: pattern == 2 ? 1 : 0)
    }

    public func frame(at time: Double) -> LaserFrame {
        guard let lastBeat else { return target }
        // Move the lighting heads smoothly between beat positions, without hard cuts.
        let x = Float(min(1, max(0, (time - lastBeat) / 0.16)))
        let blend = x * x * (3 - 2 * x)
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * blend }
        return LaserFrame(sweep: mix(previous.sweep, target.sweep), spread: mix(previous.spread, target.spread),
                          cross: mix(previous.cross, target.cross), curtain: mix(previous.curtain, target.curtain))
    }
}
