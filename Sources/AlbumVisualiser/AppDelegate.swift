import AppKit
import QuartzCore
import VisualiserCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private var controller: AppController?
    private var menuBar: MenuBarController?
    private var hotKey: HotKey?
    private let watchdog = MainThreadWatchdog()
    private var demoWindow: VisualiserWindowController?
    private var demoTimer: Timer?

    init(demo: Bool) {
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if demo { return startDemo() }

        let c = AppController()
        controller = c
        LaunchAtLogin.enableOnFirstRun()

        let m = MenuBarController()
        m.model = {
            .init(isOpen: c.isOpen, screens: c.screens, selectedScreen: c.preferredScreenID,
                  syncInfo: c.syncDescription, launchAtLogin: LaunchAtLogin.isEnabled,
                  animationStyle: c.animationStyle)
        }
        m.onToggle = { c.toggle() }
        m.onSelectScreen = { id in
            c.preferredScreenID = id
            if c.isOpen { c.stopVisualiser(); c.startVisualiser() }
        }
        m.onSync = { c.nudgeSync($0) }
        m.onLaunchAtLogin = { LaunchAtLogin.set($0) }
        m.onQuit = { NSApp.terminate(nil) }
        m.onCommand = { c.send($0) }
        m.onAnimationStyle = { c.animationStyle = $0 }
        menuBar = m

        hotKey = HotKey { c.toggle() }
        watchdog.start()
        Log.write("launched")
        // Debug: `--open` starts the visualiser straight away.
        if CommandLine.arguments.contains("--open") { c.startVisualiser() }
        // Debug: `--reopen-test` opens, closes after 3 s, reopens after 1 s more.
        if CommandLine.arguments.contains("--reopen-test") {
            c.startVisualiser()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Log.write("TEST: closing"); c.stopVisualiser() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Log.write("TEST: reopening"); c.startVisualiser() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stopVisualiser()
    }

    /// `--demo --lyrics`: made-up lines on the lyrics screen. With `--snapshot-dir`, saves frames and quits.
    private func startLyricsDemo(_ w: VisualiserWindowController, args: [String]) {
        let tl = LyricsTimeline(lines: [
            LyricLine(start: 0.5, end: 2.5, text: "See the neon"),
            LyricLine(start: 2.5, end: 4.5, text: "Party with diamonds tonight"),
            LyricLine(start: 4.5, end: 6.0, text: "Dreaming"),
        ])
        w.setLyricsMode(true)
        let start = CACurrentMediaTime()
        let snapDir = args.firstIndex(of: "--snapshot-dir").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        var shots: [(Double, String)] = [(1.6, "lyrics-1.png"), (4.3, "lyrics-2.png"), (5.2, "lyrics-3.png"), (7.0, "lyrics-gap.png")]
        var beat = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            let now = CACurrentMediaTime(), pos = now - start
            if Int(pos / 0.6) > beat { beat = Int(pos / 0.6); w.register(BeatEvent(time: now, strength: 1, isBigHit: beat % 4 == 0)) }
            w.updateLyrics(words: tl.visible(at: pos), time: now)
            if let dir = snapDir, let shot = shots.first, pos >= shot.0 {
                shots.removeFirst()
                w.snapshotLyrics(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.1))
                w.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("bg-" + shot.1))
                if shots.isEmpty { NSApp.terminate(nil) }
            }
        }
    }

    /// `--demo`: placeholder art on a synthetic 100 BPM beat, every 4th beat a big hit.
    /// With `--snapshot-dir <dir>`, saves a few frames there and quits.
    private func startDemo() {
        guard let screen = NSScreen.main else { return }
        let w = VisualiserWindowController(screen: screen)
        w.onClose = { NSApp.terminate(nil) }
        w.show()
        w.showTitle("Demo Beat", artist: "Album Visualiser")
        demoWindow = w

        let args = CommandLine.arguments
        // `--art <image file>`: use a real cover instead of the placeholder.
        if let i = args.firstIndex(of: "--art"), args.indices.contains(i + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])), let img = ArtworkLoader.decode(data) {
            w.setArtwork(img, palette: PaletteExtractor.extract(from: img))
        }
        if args.contains("--lyrics") { return startLyricsDemo(w, args: args) }
        let snapDir = args.firstIndex(of: "--snapshot-dir").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        var n = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            w.register(BeatEvent(time: CACurrentMediaTime(), strength: 1, isBigHit: n % 4 == 0))
            if let dir = snapDir {
                let url = { (name: String) in URL(fileURLWithPath: dir).appendingPathComponent(name) }
                if n == 4 { w.snapshot(to: url("big-hit.png")) }
                if n == 5 {
                    w.snapshot(to: url("normal-beat.png"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { w.snapshot(to: url("rest.png")) }
                }
                if n >= 7 { NSApp.terminate(nil) }
            }
            n += 1
        }
    }
}
