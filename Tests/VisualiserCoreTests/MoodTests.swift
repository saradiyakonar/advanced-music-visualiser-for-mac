import Testing
@testable import VisualiserCore

@Suite struct MoodTrackerTests {
    func feed(_ m: inout MoodTracker, every interval: Double, from start: Double, to end: Double) {
        var t = start
        while t < end {
            m.register(BeatEvent(time: t, strength: 1, isBigHit: false))
            t += interval
        }
    }

    @Test func slowSongIsSoft() {
        var m = MoodTracker()
        feed(&m, every: 0.85, from: 0, to: 30)           // ~70 BPM
        #expect(m.intensity(at: 30) < 0.2)
    }

    @Test func fastSongIsEnergetic() {
        var m = MoodTracker()
        feed(&m, every: 0.45, from: 0, to: 30)           // ~133 BPM
        #expect(m.intensity(at: 30) > 0.8)
    }

    @Test func changesAreGradual() {
        var m = MoodTracker()
        feed(&m, every: 0.85, from: 0, to: 30)
        feed(&m, every: 0.45, from: 30, to: 31)          // one second into a fast section
        #expect(m.intensity(at: 31) < 0.5)
        feed(&m, every: 0.45, from: 31, to: 50)
        #expect(m.intensity(at: 50) > 0.8)
    }

    @Test func startsGentlyBeforeItKnows() {
        #expect(MoodTracker().intensity(at: 0) < 0.15)
    }

    @Test func styleOverridesDetection() {
        var m = MoodTracker()
        feed(&m, every: 0.45, from: 0, to: 30)
        m.style = .soft
        #expect(m.intensity(at: 30) == 0)
        m.style = .energetic
        #expect(m.intensity(at: 30) == 1)
    }

    @Test func bpmEstimate() {
        var m = MoodTracker()
        feed(&m, every: 0.5, from: 0, to: 12)
        #expect(abs((m.bpm ?? 0) - 120) < 3)
    }
}

@Suite struct SoftAnimationTests {
    @Test func softPulsesLessAndNeverGlitches() {
        var soft = VisualAnimator()
        soft.intensity = 0
        var hard = VisualAnimator()
        let big = BeatEvent(time: 1, strength: 1, isBigHit: true)
        soft.register(big)
        hard.register(big)
        let t = 1 + VisualAnimator.attack
        let s = soft.frame(at: t, paused: false), h = hard.frame(at: t, paused: false)
        #expect(s.coverScale > 1)                         // still pulses
        #expect(s.coverScale < h.coverScale)              // but gentler
        #expect(s.glitchAmount == 0)
        #expect(abs(s.tilt) < abs(h.tilt))
    }

    @Test func softPulseLingersLonger() {
        var soft = VisualAnimator()
        soft.intensity = 0
        var hard = VisualAnimator()
        let beat = BeatEvent(time: 1, strength: 1, isBigHit: false)
        soft.register(beat)
        hard.register(beat)
        let peakS = soft.frame(at: 1 + VisualAnimator.attack, paused: false).coverScale - 1
        let peakH = hard.frame(at: 1 + VisualAnimator.attack, paused: false).coverScale - 1
        let laterS = soft.frame(at: 1.5, paused: false).coverScale - 1
        let laterH = hard.frame(at: 1.5, paused: false).coverScale - 1
        #expect(laterS / peakS > laterH / peakH)          // decays more slowly, relatively
    }
}

@Suite struct AdaptiveResponseTests {
    @Test func quietFastMusicStaysGentle() {
        var quiet = MoodTracker(), loud = MoodTracker()
        for n in 0..<60 {
            let t = Double(n) * 0.45
            quiet.register(BeatEvent(time: t, strength: 1, isBigHit: false, energy: 0.08))
            loud.register(BeatEvent(time: t, strength: 1, isBigHit: false, energy: 1))
        }
        #expect(quiet.intensity(at: 27) < 0.2)
        #expect(loud.intensity(at: 27) > 0.8)
    }

    @Test func silenceAndNewTracksForgetOldTempo() {
        var mood = MoodTracker()
        for n in 0..<40 { mood.register(BeatEvent(time: Double(n) * 0.45, strength: 1, isBigHit: false)) }
        #expect(mood.tempo(at: 18) != nil)
        #expect(mood.tempo(at: 23) == nil)
        #expect(mood.intensity(at: 25) < 0.1)
        mood.style = .soft
        mood.reset()
        #expect(mood.bpm == nil)
        #expect(mood.style == .soft)
        #expect(mood.intensity(at: 26) == 0)
    }

    @Test func slowSongsHaveLessThanOnePercentZoomEvenWithFullBass() {
        var animator = VisualAnimator()
        animator.intensity = 0.08
        animator.tempo = 70
        animator.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        let frame = animator.frame(at: 1.04, paused: false, levels: BandLevels(bass: 1, mid: 1, treble: 1))
        #expect(frame.coverScale < 1.01)
        #expect(frame.glitchAmount == 0)
        #expect(frame.impact < 0.01)
    }

    @Test func tempoControlsPulseRelease() {
        var slow = VisualAnimator(), fast = VisualAnimator()
        slow.tempo = 65; fast.tempo = 150
        let beat = BeatEvent(time: 1, strength: 1, isBigHit: false)
        slow.register(beat); fast.register(beat)
        #expect(slow.frame(at: 1.4, paused: false).coverScale > fast.frame(at: 1.4, paused: false).coverScale)
    }

    @Test func weakOnsetsAreNotForcedToHalfStrength() {
        var animator = VisualAnimator()
        animator.register(BeatEvent(time: 1, strength: 0.05, isBigHit: false, energy: 0.1))
        #expect(animator.frame(at: 1.04, paused: false).coverScale < 1.005)
    }
}
