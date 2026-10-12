/// Picks which display the visualiser opens on: the saved choice if it's still
/// connected, otherwise the main display.
public enum DisplayChooser {
    public static func choose(preferredID: UInt32?, available: [UInt32], main: UInt32) -> UInt32 {
        if let p = preferredID, available.contains(p) { return p }
        return main
    }
}
