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
