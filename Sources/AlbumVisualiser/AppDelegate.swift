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
    private func startLyricsDemo(_ w: VisualiserWindowController, args: [String], bpm: Double, energy: Float) {
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
            if Int(pos * bpm / 60) > beat { beat = Int(pos * bpm / 60); w.register(BeatEvent(time: now, strength: 1, isBigHit: beat % 4 == 0, energy: energy)) }
            w.updateLyrics(words: tl.visible(at: pos), time: now)
            if let dir = snapDir, let shot = shots.first, pos >= shot.0 {
                shots.removeFirst()
                w.snapshotLyrics(to: URL(fileURLWithPath: dir).appendingPathComponent(shot.1))
                w.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("bg-" + shot.1)) {
                    if shots.isEmpty { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// `--demo`: placeholder art on a synthetic 100 BPM beat, every 4th beat a big hit.
    /// With `--snapshot-dir <dir>`, saves a few frames there and quits.
    private func startDemo() {
        guard let screen = NSScreen.main else { return }
        let w = VisualiserWindowController(screen: screen, preferences: VisualPreferences(persistChanges: false))
        w.onClose = { NSApp.terminate(nil) }
        w.onToggleLyrics = { [weak w] in
            guard let w else { return }; w.setLyricsMode(!w.lyricsMode)
        }
        w.show()
        w.showTitle("Demo Beat", artist: "Album Visualiser")
        demoWindow = w

        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        var settings = VisualSettings()
        if let name = argument("--scene"), let scene = VisualScene(rawValue: name) { settings.scene = scene }
        if args.contains("--maximal") { settings = .preset(.supernova) }
        if let name = argument("--light-palette"), let palette = VisualPalette(rawValue: name) { settings.palette = palette }
        if args.contains("--party") { settings.partyMode = true }
        w.configure(settings)
        let bpm = min(180, max(40, argument("--bpm").flatMap(Double.init) ?? 120))
        let energy = min(1, max(0, argument("--energy").flatMap(Float.init) ?? 0.85))
        var demoMood = MoodTracker()
        for n in 0..<30 { demoMood.register(BeatEvent(time: Double(n) * 60 / bpm, strength: 1, isBigHit: false, energy: energy)) }
        let automaticIntensity = demoMood.intensity(at: 30 * 60 / bpm)
        w.setMusicalResponse(intensity: automaticIntensity, tempo: bpm)
        w.onAnimationStyle = { [weak w] style in
            w?.setMusicalResponse(intensity: style == .auto ? automaticIntensity : (style == .soft ? 0 : 1), tempo: bpm)
        }
        if args.contains("--studio") { w.showStudio() }
        w.setLevelsProvider {
            let phase = CACurrentMediaTime() * bpm / 60 * 2 * Double.pi
            return BandLevels(bass: Float(0.5 + 0.45 * sin(phase)) * energy,
                              mid: Float(0.4 + 0.3 * sin(phase * 0.5)) * energy,
                              treble: Float(0.2 + 0.15 * cos(phase * 2)) * energy)
        }
        // `--art <image file>`: use a real cover instead of the placeholder.
        if let i = args.firstIndex(of: "--art"), args.indices.contains(i + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])), let img = ArtworkLoader.decode(data) {
            w.setArtwork(img, palette: PaletteExtractor.extract(from: img))
        }
        if args.contains("--lyrics") { return startLyricsDemo(w, args: args, bpm: bpm, energy: energy) }
        let snapDir = args.firstIndex(of: "--snapshot-dir").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        var n = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 60 / bpm, repeats: true) { _ in
            w.register(BeatEvent(time: CACurrentMediaTime(), strength: 1, isBigHit: n % 4 == 0, energy: energy))
            if let dir = snapDir {
                let url = { (name: String) in URL(fileURLWithPath: dir).appendingPathComponent(name) }
                if n == 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { w.snapshot(to: url("big-hit.png")) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { w.snapshot(to: url("impact-wave.png")) }
                }
                if n == 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { w.snapshot(to: url("normal-beat.png")) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { w.snapshot(to: url("rest.png")) }
                }
                if n >= 7 { NSApp.terminate(nil) }
            }
            n += 1
        }
    }
}
