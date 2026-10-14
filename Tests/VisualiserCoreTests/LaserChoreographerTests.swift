import Testing
@testable import VisualiserCore

@Suite struct LaserChoreographerTests {
    @Test func eachBeatMovesHeadsSmoothlyAndAlternatesDirection() {
        var rig = LaserChoreographer()
        rig.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        #expect(rig.frame(at: 1).sweep == 0)
        #expect(rig.frame(at: 1.08).sweep < 0)
        let first = rig.frame(at: 1.2)
        rig.register(BeatEvent(time: 1.5, strength: 1, isBigHit: false))
        #expect(rig.frame(at: 1.5).sweep == first.sweep)
        #expect(rig.frame(at: 1.7).sweep > 0)
    }
    @Test func changesPatternsAndOpensOnBigHits() {
        var rig = LaserChoreographer()
        for n in 0..<9 { rig.register(BeatEvent(time: Double(n) * 0.5, strength: 1, isBigHit: false)) }
        #expect(rig.frame(at: 4.2).cross == 1)
        for n in 9..<17 { rig.register(BeatEvent(time: Double(n) * 0.5, strength: 1, isBigHit: false)) }
        let normal = rig.frame(at: 8.2)
        #expect(normal.curtain == 1)
        rig.register(BeatEvent(time: 8.5, strength: 1, isBigHit: true))
        #expect(rig.frame(at: 8.7).spread > normal.spread)
        rig.register(BeatEvent(time: 20, strength: 1, isBigHit: false))
        #expect(rig.frame(at: 20.2).curtain == 0)
        #expect(rig.frame(at: 20.2).cross == 0)
    }
    @Test func ignoresOutOfOrderBeatsAndStaysStillWithoutNewOnsets() {
        var rig = LaserChoreographer()
        rig.register(BeatEvent(time: 1, strength: 1, isBigHit: false))
        let settled = rig.frame(at: 2)
        rig.register(BeatEvent(time: 0, strength: 1, isBigHit: true))
        #expect(rig.frame(at: 3).sweep == settled.sweep)
        #expect(rig.frame(at: 3).spread == settled.spread)
    }
}
