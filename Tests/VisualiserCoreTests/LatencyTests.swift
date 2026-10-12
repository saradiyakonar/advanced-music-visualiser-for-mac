import Foundation
import Testing
@testable import VisualiserCore

@Suite struct LatencyTests {
    @Test func holdsEventsUntilDelayElapses() {
        let c = LatencyCompensator(delay: 0.2)
        c.enqueue([BeatEvent(time: 1.0, strength: 1, isBigHit: false)])
        #expect(c.due(upTo: 1.1).isEmpty)
        let out = c.due(upTo: 1.2)
        #expect(out.count == 1)
        #expect(abs((out.first?.time ?? 0) - 1.2) < 1e-9)
    }

    @Test func releasesInOrderOnce() {
        let c = LatencyCompensator(delay: 0.1)
        c.enqueue([1.0, 1.5, 2.0].map { BeatEvent(time: $0, strength: 1, isBigHit: false) })
        let out = c.due(upTo: 5)
        #expect(out.map(\.time).map { ($0 * 10).rounded() / 10 } == [1.1, 1.6, 2.1])
        #expect(c.due(upTo: 6).isEmpty)
    }

    @Test func bluetoothDefaultOffset() {
        let s = SyncOffsetStore(store: InMemoryStore())
        #expect(s.offset(forDeviceUID: "bt", isBluetooth: true) == 0.12)
        #expect(s.offset(forDeviceUID: "wired", isBluetooth: false) == 0.0)
    }

    @Test func nudgePersistsPerDevice() {
        let backing = InMemoryStore()
        let s = SyncOffsetStore(store: backing)
        s.nudge(deviceUID: "A", isBluetooth: true, by: 0.02)
        s.nudge(deviceUID: "A", isBluetooth: true, by: 0.02)
        #expect(abs(s.offset(forDeviceUID: "A", isBluetooth: true) - 0.16) < 1e-9)
        #expect(s.offset(forDeviceUID: "B", isBluetooth: true) == 0.12)
        let reopened = SyncOffsetStore(store: backing)
        #expect(abs(reopened.offset(forDeviceUID: "A", isBluetooth: true) - 0.16) < 1e-9)
    }

    @Test func offsetIsClamped() {
        let s = SyncOffsetStore(store: InMemoryStore())
        s.nudge(deviceUID: "A", isBluetooth: false, by: 1.0)
        #expect(s.offset(forDeviceUID: "A", isBluetooth: false) == 0.6)
        s.nudge(deviceUID: "A", isBluetooth: false, by: -5)
        #expect(s.offset(forDeviceUID: "A", isBluetooth: false) == -0.3)
    }

    @Test func resetRestoresDefault() {
        let s = SyncOffsetStore(store: InMemoryStore())
        s.nudge(deviceUID: "A", isBluetooth: true, by: 0.1)
        s.reset(deviceUID: "A")
        #expect(s.offset(forDeviceUID: "A", isBluetooth: true) == 0.12)
    }
}

@Suite struct DelayedLevelsTests {
    @Test func levelsAreDelayedLikeBeats() {
        let c = LatencyCompensator(delay: 0.2)
        c.enqueueLevels(BandLevels(bass: 0.3, mid: 0, treble: 0), at: 1.0)
        c.enqueueLevels(BandLevels(bass: 0.9, mid: 0, treble: 0), at: 1.1)
        #expect(c.levels(at: 1.15) == nil)
        #expect(c.levels(at: 1.25)?.bass == 0.3)
        #expect(c.levels(at: 1.35)?.bass == 0.9)
        #expect(c.levels(at: 2.0)?.bass == 0.9) // holds the latest once caught up
    }
}
