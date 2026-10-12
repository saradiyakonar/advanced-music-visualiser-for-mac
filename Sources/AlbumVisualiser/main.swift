import AppKit

let args = CommandLine.arguments

if args.contains("--diagnose") {
    Diagnose.run()
}

let app = NSApplication.shared
let delegate = AppDelegate(demo: args.contains("--demo"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
