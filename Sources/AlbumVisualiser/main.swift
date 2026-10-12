import AppKit
import VisualiserCore

let args = CommandLine.arguments

// Debug: `--palette <image file>` prints the colours extracted from an image.
if let i = args.firstIndex(of: "--palette"), args.indices.contains(i + 1) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
    let img = ArtworkLoader.decode(data)!
    let p = PaletteExtractor.extract(from: img)
    print(p == PaletteExtractor.fallback ? "FALLBACK" : "album colours:",
          p.map { String(format: "#%02x%02x%02x", Int($0.r * 255), Int($0.g * 255), Int($0.b * 255)) }.joined(separator: " "))
    exit(0)
}

if args.contains("--diagnose") {
    Diagnose.run()
}

let app = NSApplication.shared
let delegate = AppDelegate(demo: args.contains("--demo"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
