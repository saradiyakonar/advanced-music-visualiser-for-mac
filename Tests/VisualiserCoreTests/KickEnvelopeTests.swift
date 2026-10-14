import Testing
@testable import VisualiserCore

@Suite struct KickEnvelopeTests {
    let attack = VisualAnimator.attack

    @Test func restingFrameHasNoKick() {
        let a = VisualAnimator()
        let f = a.frame(at: 10, paused: false)
        #expect(f.coverScale == 1)
        #expect(abs(f.glowOpacity - 0.35) < 1e-6)
        #expect(f.glitchAmount == 0)
        #expect(f.slicesVisible == false)
        #expect(f.tilt == 0)
    }

    @Test func attackRisesInsteadOfJumping() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        let atBeat = a.frame(at: 1, paused: false).coverScale
        let midAttack = a.frame(at: 1 + attack / 2, paused: false).coverScale
        let peak = a.frame(at: 1 + attack, paused: false).coverScale
        #expect(atBeat < midAttack && midAttack < peak)
        #expect(atBeat < 1.05) // no instant jump to full size
    }

    @Test func normalBeatPeaksWithoutGlitch() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        let f = a.frame(at: 1 + attack, paused: false)
        #expect(abs(f.coverScale - 1.108) < 0.001)
        #expect(f.glitchAmount == 0)
    }

    @Test func bigHitGlitches() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        let f = a.frame(at: 1 + attack, paused: false)
        #expect(abs(f.coverScale - 1.18) < 0.001)
        #expect(f.glitchAmount == 1)
        #expect(f.slicesVisible)
        #expect(a.frame(at: 1.7, paused: false).glitchAmount == 0)
    }

    @Test func envelopeDecays() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        let peak = a.frame(at: 1 + attack, paused: false).coverScale
        let mid = a.frame(at: 1.2, paused: false).coverScale
        let late = a.frame(at: 1.55, paused: false).coverScale
        #expect(mid < peak)
        #expect(mid > late)
    }

    @Test func pausedBreathesAndIgnoresBeats() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        let f = a.frame(at: 1, paused: true)
        #expect(f.coverScale == 1)
        #expect(f.glitchAmount == 0)
        #expect(f.glowOpacity >= 0.15 && f.glowOpacity <= 0.35)
    }

    @Test func eachBeatBumpsSerial() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        a.register(BeatEvent(time: 2, strength: 1, isBigHit: true))
        #expect(a.frame(at: 2, paused: false).beatSerial == 2)
    }

    @Test func tiltAlternatesBetweenBeats() {
        var a = VisualAnimator()
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        let first = a.frame(at: 1 + attack, paused: false).tilt
        a.register(BeatEvent(time: 2, strength: 1, isBigHit: false))
        let second = a.frame(at: 2 + attack, paused: false).tilt
        #expect(first != 0)
        #expect(first.sign != second.sign)
    }

    @Test func colourFlowAdvancesWithoutJumps() {
        var a = VisualAnimator()
        var last = a.frame(at: 0.99, paused: false).colourFlow
        a.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        var t = 1.0
        while t < 3 {
            let flow = a.frame(at: t, paused: false).colourFlow
            #expect(flow >= last)              // only moves forward
            #expect(flow - last < 0.02)        // and never jumps at a 1/120 s step
            last = flow
            t += 1.0 / 120
        }
        // a beat pushes the colours further than time alone would
        let calm = VisualAnimator().frame(at: 3, paused: false).colourFlow
        #expect(last > calm)
    }

    @Test func levelsAddContinuousMotion() {
        let a = VisualAnimator()
        let quiet = a.frame(at: 10, paused: false, levels: BandLevels(bass: 0, mid: 0, treble: 0))
        let loud = a.frame(at: 10, paused: false, levels: BandLevels(bass: 1, mid: 1, treble: 1))
        #expect(loud.coverScale > quiet.coverScale)
        #expect(loud.glowOpacity > quiet.glowOpacity)
    }
}

@Suite struct LevelSmootherTests {
    @Test func risesFastFallsSlowly() {
        var s = LevelSmoother()
        let up = s.update(BandLevels(bass: 1, mid: 1, treble: 1), dt: 1.0 / 60)
        #expect(up.bass > 0.3)
        var down = up
        for _ in 0..<3 { down = s.update(BandLevels(bass: 0, mid: 0, treble: 0), dt: 1.0 / 60) }
        #expect(down.bass > 0.2) // release is slower than attack
        #expect(down.bass < up.bass)
    }
}

@Suite struct ImpactEnvelopeTests {
    @Test func onlyStrongBigHitsTriggerWaves() {
        for beat in [BeatEvent(time: 1, strength: 1, isBigHit: false),
                     BeatEvent(time: 1, strength: 0.5, isBigHit: true)] {
            var animator = VisualAnimator()
            animator.register(beat)
            #expect(animator.frame(at: 1.1, paused: false).impact == 0)
        }
    }

    @Test func waveSurvivesFollowingBeatsAndHasCooldown() {
        var animator = VisualAnimator()
        animator.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        let peak = animator.frame(at: 1.06, paused: false)
        #expect(peak.impact > 0.8)
        animator.register(BeatEvent(time: 1.3, strength: 1, isBigHit: false))
        animator.register(BeatEvent(time: 1.6, strength: 1, isBigHit: true))
        let later = animator.frame(at: 1.7, paused: false)
        #expect(later.impact > 0 && later.impact < peak.impact)
        #expect(later.impactProgress > 0.6)
        #expect(animator.frame(at: 2.2, paused: false).impact == 0)
        animator.register(BeatEvent(time: 2.5, strength: 1, isBigHit: true))
        #expect(animator.frame(at: 2.56, paused: false).impact > 0.8)
    }

    @Test func pausedSoftAndFutureHitsDoNotProduceImpact() {
        var animator = VisualAnimator()
        animator.register(BeatEvent(time: 1, strength: 1, isBigHit: true))
        #expect(animator.frame(at: 0.9, paused: false).impact == 0)
        #expect(animator.frame(at: 1.1, paused: true).impact == 0)
        animator.intensity = 0
        #expect(animator.frame(at: 1.1, paused: false).impact == 0)
    }
}

@Suite struct RhythmResponseTests {
    @Test func quickeningTriggersDropAndStrongerPulsesBeforeMoodCatchesUp() {
        var animator = VisualAnimator()
        animator.intensity = 0.12
        for time in [0.0, 0.8, 1.6, 2.4, 3.2, 4.0] {
            animator.register(BeatEvent(time: time, strength: 1, isBigHit: false, energy: 0.8))
        }
        let slow = animator.frame(at: 4.06, paused: false)
        animator.register(BeatEvent(time: 4.35, strength: 1, isBigHit: false, energy: 0.8))
        #expect(animator.frame(at: 4.41, paused: false).drop == 0)
        animator.register(BeatEvent(time: 4.7, strength: 1, isBigHit: false, energy: 0.8))
        let fast = animator.frame(at: 4.76, paused: false)
        #expect(fast.drop > 0.6)
        #expect(fast.backgroundPulse > slow.backgroundPulse)
        #expect(fast.coverScale > slow.coverScale)
        #expect(fast.rhythmDrive > slow.rhythmDrive)
        #expect(animator.frame(at: 8, paused: false).drop == 0)
        #expect(animator.frame(at: 8, paused: false).rhythmDrive < 0.02)
        #expect(animator.frame(at: 4.76, paused: true).backgroundPulse == 0)
        animator.intensity = 0
        #expect(animator.frame(at: 4.76, paused: false).drop == 0)
        #expect(animator.frame(at: 4.76, paused: false).rhythmDrive == 0)
    }

    @Test func energyJumpTriggersDropButSteadyBeatsAndLongSilenceDoNot() {
        var animator = VisualAnimator()
        for n in 0..<6 {
            animator.register(BeatEvent(time: Double(n) * 0.5, strength: 1, isBigHit: false, energy: 0.15))
            #expect(animator.frame(at: Double(n) * 0.5 + 0.06, paused: false).drop == 0)
        }
        animator.register(BeatEvent(time: 3, strength: 1, isBigHit: false, energy: 0.9))
        #expect(animator.frame(at: 3.06, paused: false).drop > 0.7)
        animator.register(BeatEvent(time: 10, strength: 1, isBigHit: false, energy: 1))
        #expect(animator.frame(at: 10.06, paused: false).drop == 0)
        #expect(animator.frame(at: 10.06, paused: false).rhythmDrive == 0)
    }
}
