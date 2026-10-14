import Accelerate
import Foundation

/// Bass / mid / treble energy, each normalised 0...1 against its own decaying peak.
public struct BandLevels: Sendable, Equatable {
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public init(bass: Float, mid: Float, treble: Float) {
        self.bass = bass; self.mid = mid; self.treble = treble
    }
}

/// Real-time beat detector: spectral-flux onsets weighted to the bass band, with an
/// adaptive threshold, plus a "big hit" flag for beats that stand out from recent ones.
///
/// Feed it mono Float samples in chunks of any size; it returns the beats it found
/// in each chunk, timestamped on the caller's clock.
public final class BeatDetector {
    public private(set) var levels = BandLevels(bass: 0, mid: 0, treble: 0)

    private let sampleRate: Double
    private let fftSize: Int
    private let hopSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]

    private let bassBins: Range<Int>
    private let midBins: Range<Int>
    private let trebleBins: Range<Int>
    private let fluxBins: Range<Int>

    // Sample buffer not yet consumed by a full frame, and the time of its first sample.
    private var pending: [Float] = []
    private var pendingStartTime: Double = 0

    private var prevMags: [Float]
    private var hasPrev = false

    // Onset function history (≈1 s) for the adaptive threshold.
    private var onsetHistory: [Float] = []
    private let onsetHistoryLength: Int
    private var onsetPeak: Float = 0

    // One-frame lookahead for peak picking.
    private var candidate: (onset: Float, time: Double, bass: Float, rms: Float)?
    private var previousOnset: Float = 0

    // An accepted onset waits a few frames so its bass/loudness can be measured at
    // the kick's peak rather than its first (partial) frame.
    private var held: (onset: Float, time: Double, bass: Float, rms: Float, framesLeft: Int)?
    private let holdFrames = 3

    private var lastOnsetTime = -Double.infinity
    private var lastBigHitTime = -Double.infinity

    // Recent beats (≈4 s) and recent frame loudness, for big-hit detection.
    private var recentBeats: [(time: Double, bass: Float)] = []
    private var rmsHistory: [Float] = []
    private let rmsHistoryLength: Int

    private var bandPeaks: (Float, Float, Float) = (1e-6, 1e-6, 1e-6)

    // Tuning. Values validated by BeatDetectorTests.
    private let minGap = 0.25            // seconds between onsets
    private let minOnset: Float = 0.01   // absolute floor; a steady tone's frame-to-frame wobble sits ~1e-4
    private let thresholdMultiplier: Float = 1.5
    private let thresholdPeakFraction: Float = 0.1
    private let silenceRMS: Float = 1e-4
    private let bigHitSigma: Float = 1.5
    private let bigHitRatio: Float = 1.4 // must also beat the recent mean by 40%
    private let bigHitMinBeats = 4
    private let bigHitMinGap = 1.0
    private let beatHistorySeconds = 4.0

    public init(sampleRate: Double, fftSize: Int = 1024, hopSize: Int = 512) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)

        let binHz = sampleRate / Double(fftSize)
        func bin(_ hz: Double) -> Int { max(1, min(fftSize / 2, Int((hz / binHz).rounded()))) }
        bassBins = bin(30)..<max(bin(150), bin(30) + 1)
        midBins = bassBins.upperBound..<bin(2000)
        trebleBins = midBins.upperBound..<bin(8000)
        fluxBins = 1..<bin(8000)

        prevMags = [Float](repeating: 0, count: fftSize / 2)
        let framesPerSecond = sampleRate / Double(hopSize)
        onsetHistoryLength = max(8, Int(framesPerSecond))
        rmsHistoryLength = max(8, Int(framesPerSecond * beatHistorySeconds))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func process(_ samples: UnsafeBufferPointer<Float>, startTime: Double) -> [BeatEvent] {
        if pending.isEmpty { pendingStartTime = startTime }
        pending.append(contentsOf: samples)

        var events: [BeatEvent] = []
        var offset = 0
        while pending.count - offset >= fftSize {
            let frameTime = pendingStartTime + Double(offset + fftSize / 2) / sampleRate
            if let e = processFrame(start: offset, time: frameTime) { events.append(e) }
            offset += hopSize
        }
        if offset > 0 {
            pending.removeFirst(offset)
            pendingStartTime += Double(offset) / sampleRate
        }
        return events
    }

    // MARK: - Per frame

    private func processFrame(start: Int, time: Double) -> BeatEvent? {
        var frame = [Float](repeating: 0, count: fftSize)
        pending.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
        }
        let rms: Float = pending.withUnsafeBufferPointer { p in
            vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: p[start..<(start + fftSize)]))
        }

        if rms < silenceRMS {
            // Silence: decay levels, forget the previous spectrum, report nothing.
            levels = BandLevels(bass: levels.bass * 0.9, mid: levels.mid * 0.9, treble: levels.treble * 0.9)
            hasPrev = false
            candidate = nil
            previousOnset = 0
            defer { held = nil }
            return held.map(finalize)
        }

        let mags = magnitudes(of: frame)
        updateLevels(mags)

        var bassEnergy: Float = 0
        for k in bassBins { bassEnergy += mags[k] * mags[k] }

        var onset: Float = 0
        if hasPrev {
            var bassFlux: Float = 0, fullFlux: Float = 0
            for k in bassBins { bassFlux += max(0, log1p(100 * mags[k]) - log1p(100 * prevMags[k])) }
            for k in fluxBins { fullFlux += max(0, log1p(100 * mags[k]) - log1p(100 * prevMags[k])) }
            onset = 0.6 * bassFlux / Float(bassBins.count) + 0.4 * fullFlux / Float(fluxBins.count)
        }
        prevMags = mags
        hasPrev = true

        rmsHistory.append(rms)
        if rmsHistory.count > rmsHistoryLength { rmsHistory.removeFirst() }

        var event: BeatEvent?
        if var h = held {
            h.bass = max(h.bass, bassEnergy)
            h.rms = max(h.rms, rms)
            h.framesLeft -= 1
            if h.framesLeft <= 0 {
                event = finalize(h)
                held = nil
            } else {
                held = h
            }
        }

        // Peak picking with one frame of lookahead: the candidate is an onset if this frame is lower.
        if let c = candidate, onset <= c.onset, accept(c) {
            if let h = held { event = finalize(h) } // a new onset flushes any still-held one
            held = (c.onset, c.time, max(c.bass, bassEnergy), max(c.rms, rms), holdFrames - 1)
        }
        candidate = (onset > previousOnset) ? (onset, time, bassEnergy, rms) : nil
        previousOnset = onset

        onsetPeak = max(onset, onsetPeak * 0.999)
        onsetHistory.append(onset)
        if onsetHistory.count > onsetHistoryLength { onsetHistory.removeFirst() }
        return event
    }

    private func accept(_ c: (onset: Float, time: Double, bass: Float, rms: Float)) -> Bool {
        let threshold = median(onsetHistory) * thresholdMultiplier + thresholdPeakFraction * onsetPeak
        guard c.onset > threshold, c.onset > minOnset, c.time - lastOnsetTime >= minGap else { return false }
        lastOnsetTime = c.time
        return true
    }

    private func finalize(_ c: (onset: Float, time: Double, bass: Float, rms: Float, framesLeft: Int)) -> BeatEvent {
        recentBeats.removeAll { c.time - $0.time > beatHistorySeconds }
        var isBig = false
        if recentBeats.count >= bigHitMinBeats, c.time - lastBigHitTime >= bigHitMinGap {
            let values = recentBeats.map(\.bass)
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            let sigma = variance.squareRoot()
            let meanRMS = rmsHistory.reduce(0, +) / Float(max(rmsHistory.count, 1))
            isBig = c.bass > mean + bigHitSigma * sigma && c.bass > mean * bigHitRatio && c.rms > meanRMS
        }
        if isBig { lastBigHitTime = c.time }
        recentBeats.append((c.time, c.bass))

        let strength = onsetPeak > 0 ? min(1, c.onset / onsetPeak) : 0
        // Keep quiet transients quiet even when they are the strongest onset in a passage.
        let energy = min(1, max(0, (c.rms - 0.012) / 0.18))
        return BeatEvent(time: c.time, strength: strength, isBigHit: isBig, energy: energy)
    }

    // MARK: - Helpers

    private func magnitudes(of frame: [Float]) -> [Float] {
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // bin 0's imag slot holds Nyquist; drop it
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var scale = 1 / Float(fftSize)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
        return mags
    }

    private func updateLevels(_ mags: [Float]) {
        func sum(_ r: Range<Int>) -> Float { r.isEmpty ? 0 : r.reduce(0) { $0 + mags[$1] } / Float(r.count) }
        let b = sum(bassBins), m = sum(midBins), t = sum(trebleBins)
        bandPeaks = (max(b, bandPeaks.0 * 0.995), max(m, bandPeaks.1 * 0.995), max(t, bandPeaks.2 * 0.995))
        levels = BandLevels(bass: min(1, b / bandPeaks.0), mid: min(1, m / bandPeaks.1), treble: min(1, t / bandPeaks.2))
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }
}
