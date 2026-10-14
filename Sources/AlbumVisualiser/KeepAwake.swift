import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import VisualiserCore

/// Keeps the display (and Mac) awake while the visualiser is open and plugged into power.
/// Follows the charger being connected or removed while open.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private var visualiserOpen = false
    private var powerSource: CFRunLoopSource?

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<KeepAwake>.fromOpaque(ctx).takeUnretainedValue().update()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
    }

    deinit {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        release()
    }

    func setVisualiserOpen(_ open: Bool) {
        visualiserOpen = open
        update()
    }

    /// True only when macOS positively reports AC power; any failure counts as battery,
    /// so a bad reading can never keep the Mac awake on battery.
    static var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info) else { return false }
        return ((type.takeUnretainedValue() as NSString) as String) == kIOPMACPowerKey
    }

    private func update() {
        let want = KeepAwakePolicy.shouldKeepAwake(visualiserOpen: visualiserOpen, onPower: Self.onPower)
        if want && !holding {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Album Visualiser is showing" as CFString, &assertion)
            holding = ok == kIOReturnSuccess
            Log.write("keep awake: \(holding ? "on" : "failed") (power source: AC)")
        } else if !want && holding {
            release()
            Log.write("keep awake: off (\(visualiserOpen ? "on battery" : "visualiser closed"))")
        }
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }
}
