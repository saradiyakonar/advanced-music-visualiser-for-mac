import Foundation
import Testing
@testable import VisualiserCore

/// Deterministic test signals.
enum Synth {
    static let sampleRate = 44_100.0

    struct Track {
        var samples: [Float]
        var kickTimes: [Double]
        var accented: [Bool]
    }

    /// Kicks are 80 ms 60 Hz sine bursts with exponential decay over low-level noise.
    static func kickTrack(bpm: Double, seconds: Double, accentEvery: Int = 0, accentGain: Float = 3,
                          kickGain: Float = 0.3, gain: Float = 1, noise: Float = 0.01) -> Track {
        let n = Int(seconds * sampleRate)
        var s = [Float](repeating: 0, count: n)
        var rng = LCG(seed: 42)
        for i in 0..<n { s[i] = noise * (rng.nextFloat() * 2 - 1) }

        var times: [Double] = []
        var accented: [Bool] = []
        let interval = 60 / bpm
        var t = 0.25
        var k = 0
        while t < seconds - 0.1 {
            let isAccent = accentEvery > 0 && k % accentEvery == 0
            let amp = kickGain * (isAccent ? accentGain : 1)
            let start = Int(t * sampleRate)
            let len = Int(0.08 * sampleRate)
            for j in 0..<len where start + j < n {
                let tt = Double(j) / sampleRate
                s[start + j] += amp * Float(sin(2 * .pi * 60 * tt) * exp(-tt / 0.03))
            }
            times.append(t)
            accented.append(isAccent)
            t += interval
            k += 1
        }
        if gain != 1 { for i in 0..<n { s[i] *= gain } }
        return Track(samples: s, kickTimes: times, accented: accented)
    }

    static func tone(hz: Double, seconds: Double, amp: Float = 0.3) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    static func run(_ samples: [Float], chunk: Int = 512) -> (events: [BeatEvent], detector: BeatDetector) {
        let d = BeatDetector(sampleRate: sampleRate)
        var events: [BeatEvent] = []
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            samples[i..<end].withUnsafeBufferPointer { buf in
                events += d.process(buf, startTime: Double(i) / sampleRate)
            }
            i = end
        }
        return (events, d)
    }

    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextFloat() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }
}

@Suite struct BeatDetectorTests {
    /// Index of the detected event within 30 ms of `t`, if any.
    func match(_ t: Double, in events: [BeatEvent]) -> Int? {
        events.firstIndex { abs($0.time - t) <= 0.03 }
    }

    @Test func detectsSteadyKicks() {
        let track = Synth.kickTrack(bpm: 120, seconds: 8)
        let events = Synth.run(track.samples).events.filter { $0.time > 1 }
        let expected = track.kickTimes.filter { $0 > 1 }
        let hits = expected.filter { match($0, in: events) != nil }.count
        let extras = events.filter { e in !expected.contains { abs($0 - e.time) <= 0.03 } }.count
        #expect(Double(hits) / Double(expected.count) >= 0.9, "recall \(hits)/\(expected.count)")
        #expect(Double(extras) <= 0.1 * Double(expected.count), "extras \(extras)")
    }

    @Test func silenceProducesNothing() {
        let (events, d) = Synth.run([Float](repeating: 0, count: Int(5 * Synth.sampleRate)))
        #expect(events.isEmpty)
        #expect(!d.levels.bass.isNaN && !d.levels.mid.isNaN && !d.levels.treble.isNaN)
    }

    @Test func steadyToneProducesNothing() {
        let events = Synth.run(Synth.tone(hz: 440, seconds: 5)).events
        #expect(events.count <= 1)
    }

    @Test func accentedKicksAreBigHits() {
        let track = Synth.kickTrack(bpm: 120, seconds: 16, accentEvery: 4)
        let events = Synth.run(track.samples).events
        var accentBig = 0, accentTotal = 0, normalBig = 0, normalTotal = 0
        for (t, acc) in zip(track.kickTimes, track.accented) where t > 4 {
            let big = match(t, in: events).map { events[$0].isBigHit } ?? false
            if acc { accentTotal += 1; if big { accentBig += 1 } }
            else { normalTotal += 1; if big { normalBig += 1 } }
        }
        #expect(Double(accentBig) >= 0.75 * Double(accentTotal), "accents \(accentBig)/\(accentTotal)")
        #expect(Double(normalBig) <= 0.1 * Double(normalTotal), "normals \(normalBig)/\(normalTotal)")
    }

    @Test func quietTrackStillGetsBigHits() {
        let track = Synth.kickTrack(bpm: 120, seconds: 16, accentEvery: 4, gain: 0.05)
        let events = Synth.run(track.samples).events
        let accents = zip(track.kickTimes, track.accented).filter { $0.0 > 4 && $0.1 }.map(\.0)
        let big = accents.filter { t in match(t, in: events).map { events[$0].isBigHit } ?? false }.count
        #expect(Double(big) >= 0.5 * Double(accents.count), "quiet accents \(big)/\(accents.count)")
    }

    @Test func uniformLoudTrackRarelyGlitches() {
        let track = Synth.kickTrack(bpm: 120, seconds: 16, kickGain: 0.8)
        let events = Synth.run(track.samples).events
        let big = events.filter(\.isBigHit).count
        #expect(Double(big) <= 0.15 * Double(max(events.count, 1)), "big \(big)/\(events.count)")
    }

    @Test func chunkingDoesNotChangeResults() {
        let track = Synth.kickTrack(bpm: 120, seconds: 8)
        let a = Synth.run(track.samples, chunk: 512).events.count
        let b = Synth.run(track.samples, chunk: 1337).events.count
        #expect(abs(a - b) <= 1, "\(a) vs \(b)")
    }

    @Test func strengthIsNormalised() {
        let track = Synth.kickTrack(bpm: 120, seconds: 6)
        for e in Synth.run(track.samples).events {
            #expect(e.strength >= 0 && e.strength <= 1)
        }
    }
}
