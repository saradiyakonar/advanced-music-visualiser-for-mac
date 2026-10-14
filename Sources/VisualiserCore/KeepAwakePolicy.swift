/// When to stop the Mac sleeping: only while the visualiser is open and on power,
/// so it never drains the battery.
public enum KeepAwakePolicy {
    public static func shouldKeepAwake(visualiserOpen: Bool, onPower: Bool) -> Bool {
        visualiserOpen && onPower
    }
}
