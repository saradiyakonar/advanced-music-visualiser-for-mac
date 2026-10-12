import Foundation

/// Holds beat events until the matching sound actually comes out of the speakers.
///
/// Captured audio is analysed before it's heard (Bluetooth can add 150–300 ms), so each
/// event is released at `time + delay`, with its time rewritten to match.
/// `enqueue` is called from the audio thread and `due` from the main thread.
public final class LatencyCompensator: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [BeatEvent] = []
    private var _delay: Double

    public var delay: Double {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    public init(delay: Double = 0) {
        _delay = delay
    }

    public func enqueue(_ events: [BeatEvent]) {
        guard !events.isEmpty else { return }
        lock.withLock { queue.append(contentsOf: events) }
    }

    private var levelQueue: [(time: Double, levels: BandLevels)] = []
    private var currentLevels: BandLevels?

    public func enqueueLevels(_ levels: BandLevels, at time: Double) {
        lock.withLock {
            levelQueue.append((time, levels))
            if levelQueue.count > 512 { levelQueue.removeFirst(levelQueue.count - 512) }
        }
    }

    /// The most recent band levels whose sound has reached the speakers by `now`.
    public func levels(at now: Double) -> BandLevels? {
        lock.withLock {
            while let first = levelQueue.first, first.time + _delay <= now {
                currentLevels = levelQueue.removeFirst().levels
            }
            return currentLevels
        }
    }

    public func due(upTo now: Double) -> [BeatEvent] {
        lock.withLock {
            var out: [BeatEvent] = []
            while let first = queue.first, first.time + _delay <= now {
                var e = queue.removeFirst()
                e.time += _delay
                out.append(e)
            }
            return out
        }
    }
}
