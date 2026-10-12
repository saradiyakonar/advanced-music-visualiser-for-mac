import AppKit
import QuartzCore
import VisualiserCore

/// Wires now-playing, audio capture, beat detection, latency compensation and the window.
/// Nothing here runs while the visualiser is closed except the menu bar item and hotkey.
final class AppController {
    static let noMusicMessage = "Play something on Spotify or Apple Music"
    static let noLyricsMessage = "No lyrics for this song"

    private let nowPlaying = NowPlayingService()
    private lazy var artwork = ArtworkLoader(musicRawData: { [weak self] done in
        guard let self else { return done(nil) }
        self.nowPlaying.musicArtworkData(completion: done)
    })
    private let lyrics = LyricsService()
    /// L pressed: show lyrics whenever the current song has them.
    private var lyricsWanted = false
    private var timeline: LyricsTimeline?
    private let tap = AudioTapCapture()
    private let compensator = LatencyCompensator()
    private let syncStore = SyncOffsetStore(store: UserDefaults.standard)
    private let defaults = UserDefaults.standard
    private let keepAwake = KeepAwake()

    private var window: VisualiserWindowController?
    private var frameTimer: Timer?
    private var detector: BeatDetector?        // touched only on the tap's audio queue
    private var shownTrackID: String?
    private var output: OutputDeviceInfo?

    var isOpen: Bool { window != nil }

    init() {
        OutputLatency.observeChanges { [weak self] in self?.outputChanged() }
    }

    // MARK: - Open / close

    func toggle() { isOpen ? stopVisualiser() : startVisualiser() }

    func startVisualiser() {
        guard window == nil else { return }
        Log.write("start visualiser")
        let w = VisualiserWindowController(screen: targetScreen())
        guard w.isAvailable else {
            NSLog("Album Visualiser: Metal unavailable")
            return
        }
        w.onClose = { [weak self] in self?.stopVisualiser() }
        w.onToggleLyrics = { [weak self] in self?.toggleLyrics() }
        w.onLyricsNudge = { [weak self] d in self?.nudgeLyrics(d) }
        w.onCommand = { [weak self] c in self?.send(c) }
        w.setLevelsProvider { [weak self] in self?.compensator.levels(at: CACurrentMediaTime()) }
        window = w
        keepAwake.setVisualiserOpen(true)
        output = OutputLatency.current()
        updateDelay()
        w.show()

        nowPlaying.onChange = { [weak self] in self?.handle($0) }
        nowPlaying.start()

        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self, let w = self.window else { return }
            let now = CACurrentMediaTime()
            if self.tapState == .idle, let t = self.nowPlaying.current, now - self.lastTapAttempt > 3 {
                self.ensureTap(bundleID: t.app.bundleID)
            }
            for beat in self.compensator.due(upTo: now) {
                self.mood.register(beat)
                w.register(beat)
            }
            w.setIntensity(self.mood.intensity(at: now))
            if w.lyricsMode, let tl = self.timeline, let clock = self.nowPlaying.clock {
                let pos = clock.position(at: now, outputDelay: self.compensator.delay) + self.lyricsOffset
                w.updateLyrics(words: tl.visible(at: pos), time: now)
            }
        }
    }

    func stopVisualiser() {
        nowPlaying.stop()
        nowPlaying.onChange = nil
        frameTimer?.invalidate()
        frameTimer = nil
        stopTap()
        shownTrackID = nil
        lyricsWanted = false
        timeline = nil
        _ = compensator.due(upTo: .infinity)
        window?.close()
        window = nil
        keepAwake.setVisualiserOpen(false)
    }

    // MARK: - Now playing

    private func handle(_ track: TrackInfo?) {
        guard let w = window else { return }
        Log.write("now playing: \(track.map { "\($0.title) [\($0.app.rawValue), \($0.state)] id=\($0.id)" } ?? "none")")
        guard let track else {
            shownTrackID = nil
            w.setArtwork(nil, palette: [])
            w.setPaused(true)
            w.showMessage(Self.noMusicMessage)
            stopTap()
            return
        }

        w.showMessage(nil)
        w.setPaused(track.state != .playing)

        if track.id != shownTrackID {
            shownTrackID = track.id
            timeline = nil
            if lyricsWanted { loadLyrics(for: track, announceMissing: false) }
            w.showTitle(track.title, artist: track.artist)
            // The previous cover stays up until the new one has loaded.
            let t0 = CACurrentMediaTime()
            Log.write("artwork load start: \(track.artworkURL?.absoluteString ?? "no url")")
            artwork.load(for: track) { [weak self] image in
                Log.write(String(format: "artwork load done in %.0f ms: %@", (CACurrentMediaTime() - t0) * 1000,
                                 image == nil ? "none (placeholder)" : "\(image!.width)x\(image!.height)"))
                guard let self, self.shownTrackID == track.id else {
                    Log.write("artwork dropped: track changed (shown=\(self?.shownTrackID ?? "nil"))")
                    return
                }
                let palette = image.map { PaletteExtractor.extract(from: $0) } ?? PaletteExtractor.fallback
                self.window?.setArtwork(image, palette: palette)
            }
        }

        // Start listening as soon as a song is loaded (even paused), so play reacts instantly.
        ensureTap(bundleID: track.app.bundleID)
    }

    // MARK: - Playback controls and animation style

    func send(_ command: NowPlayingService.Command) { nowPlaying.send(command) }

    private lazy var mood: MoodTracker = {
        var m = MoodTracker()
        m.style = animationStyle
        return m
    }()

    var animationStyle: AnimationStyle {
        get { AnimationStyle(rawValue: defaults.string(forKey: "animation.style") ?? "") ?? .auto }
        set {
            defaults.set(newValue.rawValue, forKey: "animation.style")
            mood.style = newValue
        }
    }

    // MARK: - Lyrics

    /// Manual lyric timing correction in seconds; positive shows words earlier. Saved.
    private var lyricsOffset: Double {
        get { defaults.double(forKey: "lyrics.offset") }
        set { defaults.set(newValue, forKey: "lyrics.offset") }
    }

    private func nudgeLyrics(_ delta: Double) {
        guard let w = window, w.lyricsMode else { return }
        lyricsOffset = min(2, max(-2, ((lyricsOffset + delta) * 10).rounded() / 10))
        let o = lyricsOffset
        w.flash(o == 0 ? "Lyrics timing: default"
                       : String(format: "Lyrics %.1f s %@", abs(o), o > 0 ? "earlier" : "later"), seconds: 1.2)
    }

    private func toggleLyrics() {
        guard let w = window else { return }
        if lyricsWanted {
            lyricsWanted = false
            w.setLyricsMode(false)
            return
        }
        guard let track = nowPlaying.current else { return w.flash(Self.noMusicMessage) }
        lyricsWanted = true
        loadLyrics(for: track, announceMissing: true)
    }

    /// Shows lyrics for `track` if LRCLIB has them; otherwise the cover stays.
    private func loadLyrics(for track: TrackInfo, announceMissing: Bool) {
        lyrics.fetch(track, duration: nowPlaying.duration) { [weak self] tl in
            guard let self, let w = self.window, self.lyricsWanted, self.nowPlaying.current?.id == track.id else { return }
            self.timeline = tl
            w.setLyricsMode(tl != nil)
            if tl == nil {
                if announceMissing {
                    self.lyricsWanted = false // nothing to show: L stays off
                    w.flash(Self.noLyricsMessage)
                }
            }
        }
    }

    // MARK: - Audio capture

    /// Starting a process tap takes ~2.7 s (longer if macOS is showing a permission
    /// prompt), so all tap control runs on its own serial queue, never the main thread.
    private let tapQueue = DispatchQueue(label: "album-visualiser.tap-control", qos: .userInitiated)
    private enum TapState: Equatable { case idle, starting(String), running(String) }
    private var tapState = TapState.idle      // main thread only
    private var tapGeneration = 0             // main thread only; invalidates stale starts
    private var lastTapAttempt = 0.0

    /// Starts the tap for `bundleID` unless it's already running or starting.
    private func ensureTap(bundleID: String) {
        if tapState == .running(bundleID) || tapState == .starting(bundleID) { return }
        startTap(bundleID: bundleID)
    }

    private func startTap(bundleID: String) {
        tapGeneration += 1
        let gen = tapGeneration
        tapState = .starting(bundleID)
        lastTapAttempt = CACurrentMediaTime()
        Log.write("tap start: \(bundleID)")
        tapQueue.async { [weak self] in
            guard let self else { return }
            self.tap.stop()
            self.detector = nil // old tap is stopped, so no audio callback can be using it
            let t0 = CACurrentMediaTime()
            do {
                try self.tap.start(bundleID: bundleID) { [weak self] samples, time in
                    guard let self else { return }
                    if self.detector == nil { self.detector = BeatDetector(sampleRate: self.tap.sampleRate) }
                    let d = self.detector!
                    self.compensator.enqueue(d.process(samples, startTime: time))
                    self.compensator.enqueueLevels(d.levels, at: time)
                }
                Log.write(String(format: "tap running after %.0f ms", (CACurrentMediaTime() - t0) * 1000))
                DispatchQueue.main.async {
                    if gen == self.tapGeneration { self.tapState = .running(bundleID) }
                }
            } catch {
                // Typically the player hasn't opened its audio stream yet; retried from the frame timer.
                Log.write("tap failed: \(error)")
                DispatchQueue.main.async {
                    if gen == self.tapGeneration { self.tapState = .idle }
                }
            }
        }
    }

    private func stopTap() {
        tapGeneration += 1
        tapState = .idle
        tapQueue.async { [weak self] in self?.tap.stop() }
    }

    private var tappedBundleID: String? {
        switch tapState {
        case .idle: nil
        case .starting(let b), .running(let b): b
        }
    }

    // MARK: - Output device and sync

    private func outputChanged() {
        output = OutputLatency.current()
        updateDelay()
        if let id = tappedBundleID, isOpen { startTap(bundleID: id) } // aggregate is tied to the old device
    }

    private func updateDelay() {
        guard let o = output else { compensator.delay = 0; return }
        compensator.delay = max(0, o.reportedLatency + syncStore.offset(forDeviceUID: o.uid, isBluetooth: o.isBluetooth))
    }

    func nudgeSync(_ delta: Double?) {
        let o = output ?? OutputLatency.current()
        guard let o else { return }
        if let delta { syncStore.nudge(deviceUID: o.uid, isBluetooth: o.isBluetooth, by: delta) }
        else { syncStore.reset(deviceUID: o.uid) }
        output = o
        updateDelay()
    }

    var syncDescription: String {
        guard let o = output ?? OutputLatency.current() else { return "No output device" }
        let total = o.reportedLatency + syncStore.offset(forDeviceUID: o.uid, isBluetooth: o.isBluetooth)
        return String(format: "%@ · %+.0f ms", o.name, total * 1000)
    }

    // MARK: - Displays

    var screens: [(id: UInt32, name: String)] {
        NSScreen.screens.map { (Self.displayID($0), $0.localizedName) }
    }

    var preferredScreenID: UInt32? {
        get { (defaults.object(forKey: "display.preferred") as? NSNumber)?.uint32Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "display.preferred") }
    }

    private func targetScreen() -> NSScreen {
        let main = NSScreen.main ?? NSScreen.screens[0]
        let id = DisplayChooser.choose(preferredID: preferredScreenID, available: screens.map(\.id), main: Self.displayID(main))
        return NSScreen.screens.first { Self.displayID($0) == id } ?? main
    }

    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
