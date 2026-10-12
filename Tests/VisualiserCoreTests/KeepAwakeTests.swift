import Testing
@testable import VisualiserCore

@Suite struct KeepAwakeTests {
    @Test func onlyWhileOpenAndPluggedIn() {
        #expect(KeepAwakePolicy.shouldKeepAwake(visualiserOpen: true, onPower: true))
        #expect(!KeepAwakePolicy.shouldKeepAwake(visualiserOpen: true, onPower: false))
        #expect(!KeepAwakePolicy.shouldKeepAwake(visualiserOpen: false, onPower: true))
        #expect(!KeepAwakePolicy.shouldKeepAwake(visualiserOpen: false, onPower: false))
    }
}
