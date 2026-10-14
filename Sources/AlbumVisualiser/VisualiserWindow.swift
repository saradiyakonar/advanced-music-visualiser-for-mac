import AppKit
import ImageIO
import MetalKit
import SwiftUI
import VisualiserCore

/// Borderless window that can take key focus (needed for Esc and L).
private final class KeyWindow: NSWindow {
    var onPointer: ((NSPoint) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved || event.type == .leftMouseDragged { onPointer?(event.locationInWindow) }
        super.sendEvent(event)
    }
    var onEscape: (() -> Void)?
    var onLyricsKey: (() -> Void)?
    var onPartyKey: (() -> Void)?
    var onStudioKey: (() -> Void)?
    var onSceneKey: ((Int) -> Void)?
    var onLyricsNudge: ((Double) -> Void)?
    var onCommand: ((NowPlayingService.Command) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.keyCode == 49, !event.isARepeat { onCommand?(.playPause) }   // space
        else if event.keyCode == 124, !event.isARepeat { onCommand?(.next) }       // →
        else if event.keyCode == 123, !event.isARepeat { onCommand?(.previous) }   // ←
        else if event.charactersIgnoringModifiers?.lowercased() == "l", !event.isARepeat { onLyricsKey?() }
        else if event.charactersIgnoringModifiers?.lowercased() == "v", !event.isARepeat { onStudioKey?() }
        else if event.charactersIgnoringModifiers?.lowercased() == "p", !event.isARepeat { onPartyKey?() }
        else if let text = event.charactersIgnoringModifiers, let number = Int(text), (1...VisualScene.allCases.count).contains(number) { onSceneKey?(number - 1) }
        else if event.charactersIgnoringModifiers == "[" { onLyricsNudge?(0.1) }   // lyrics earlier
        else if event.charactersIgnoringModifiers == "]" { onLyricsNudge?(-0.1) }  // lyrics later
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class VisualControl: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        self.perform = action
        bezelStyle = .rounded
        target = self
        self.action = #selector(activate)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { perform?() }
}

/// The full-screen visual: Metal view plus title and message overlays.
final class VisualiserWindowController {
    var onClose: (() -> Void)?
    var onAnimationStyle: ((AnimationStyle) -> Void)?
    var onToggleLyrics: (() -> Void)?
    var onCommand: ((NowPlayingService.Command) -> Void)?
    /// 0 = soft, 1 = energetic; set every frame from the song's tempo.
    private var intensity: Float = 0.12
    private var tempo: Double?
    var onLyricsNudge: ((Double) -> Void)?
    private(set) var lyricsMode = false
    private let lyricsView: LyricsView

    private let window: KeyWindow
    private let metalView: MTKView
    private let renderer: MetalRenderer?
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var cursorTimer: Timer?
    private var titleHide: DispatchWorkItem?
    private let controls = NSVisualEffectView()
    private var controlsHide: DispatchWorkItem?
    private var lyricsButton: VisualControl?
    private var partyButton: VisualControl?
    private let preferences: VisualPreferences
    private var studioView: NSHostingView<VisualStudio>?
    private var coverTitleConstraint: NSLayoutConstraint?

    var animator: VisualAnimator {
        get { renderer?.animator ?? VisualAnimator() }
        set { renderer?.animator = newValue }
    }

    init(screen: NSScreen, preferences: VisualPreferences = VisualPreferences()) {
        self.preferences = preferences
        window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(red: 5 / 255, green: 3 / 255, blue: 10 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        metalView = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.preferredFramesPerSecond = min(60, screen.maximumFramesPerSecond)
        metalView.autoresizingMask = [.width, .height]
        renderer = MetalRenderer(view: metalView)
        renderer?.setArtwork(Placeholder.image, palette: PaletteExtractor.fallback)

        let content = NSView(frame: metalView.frame)
        content.addSubview(metalView)
        lyricsView = LyricsView(frame: metalView.frame)
        lyricsView.autoresizingMask = [.width, .height]
        lyricsView.isHidden = true
        content.addSubview(lyricsView)
        for label in [titleLabel, artistLabel, messageLabel] {
            label.alignment = .center
            label.textColor = .white
            label.alphaValue = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            label.wantsLayer = true
            content.addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        artistLabel.font = .systemFont(ofSize: 17, weight: .medium)
        artistLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        messageLabel.font = .systemFont(ofSize: 22, weight: .medium)

        // Title sits under the cover, clear of its largest beat size.
        let coverHalf = CGFloat(MetalRenderer.coverHalf) * min(screen.frame.width, screen.frame.height)
        let titlePosition = titleLabel.topAnchor.constraint(equalTo: content.centerYAnchor, constant: coverHalf * 1.25 + 20)
        coverTitleConstraint = titlePosition
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titlePosition,
            artistLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: content.centerYAnchor, constant: coverHalf * 1.25 + 20),
        ])
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 16
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        let mode = VisualControl("Lyrics · L") { [weak self] in self?.onToggleLyrics?() }
        lyricsButton = mode
        let studioButton = VisualControl("Visual studio · V") { [weak self] in self?.toggleStudio() }
        let party = VisualControl("Party · P") { [weak self] in self?.preferences.settings.partyMode.toggle() }
        partyButton = party
        let buttons = [
            VisualControl("Previous") { [weak self] in self?.onCommand?(.previous) },
            VisualControl("Play / pause") { [weak self] in self?.onCommand?(.playPause) },
            VisualControl("Next") { [weak self] in self?.onCommand?(.next) }, mode, party, studioButton,
            VisualControl("Close · Esc") { [weak self] in self?.onClose?() }
        ]
        let stack = NSStackView(views: buttons)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: controls.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -12)
        ])
        let studio = NSHostingView(rootView: VisualStudio(model: preferences))
        studio.translatesAutoresizingMaskIntoConstraints = false
        studio.isHidden = true
        content.addSubview(studio)
        NSLayoutConstraint.activate([
            studio.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            studio.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            studio.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -18),
            studio.widthAnchor.constraint(equalToConstant: min(360, screen.frame.width - 48))
        ])
        studioView = studio
        preferences.onClose = { [weak self] in self?.toggleStudio() }
        preferences.onChange = { [weak self] settings in self?.apply(settings) }
        preferences.onResponseStyle = { [weak self] style in self?.onAnimationStyle?(style) }
        apply(preferences.settings)
        renderer?.animator.intensity = intensity
        window.acceptsMouseMovedEvents = true
        window.onPointer = { [weak self] point in
            guard let self else { return }
            self.renderer?.pointer = SIMD2(Float(point.x / max(1, content.bounds.width) - 0.5),
                                          Float(0.5 - point.y / max(1, content.bounds.height)))
            self.revealControls()
        }
        window.contentView = content
        window.onEscape = { [weak self] in
            guard let self else { return }
            if self.studioView?.isHidden == false { self.toggleStudio() } else { self.onClose?() }
        }
        window.onPartyKey = { [weak self] in self?.preferences.settings.partyMode.toggle() }
        window.onStudioKey = { [weak self] in self?.toggleStudio() }
        window.onSceneKey = { [weak self] index in self?.preferences.settings.scene = VisualScene.allCases[index] }
        window.onLyricsKey = { [weak self] in self?.onToggleLyrics?() }
        window.onLyricsNudge = { [weak self] d in self?.onLyricsNudge?(d) }
        window.onCommand = { [weak self] c in self?.onCommand?(c) }
    }

    var isAvailable: Bool { renderer != nil }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        metalView.isPaused = false
        revealControls()
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if self?.controls.isHidden == true, self?.studioView?.isHidden == true { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    func close() {
        controlsHide?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        metalView.isPaused = true
        window.orderOut(nil)
        NSApp.presentationOptions = []
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func setArtwork(_ image: CGImage?, palette: [RGB]) {
        renderer?.setArtwork(image ?? Placeholder.image, palette: image == nil ? PaletteExtractor.fallback : palette)
        let glow = renderer?.palette.first ?? PaletteExtractor.fallback[0]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: CGFloat(glow.r), green: CGFloat(glow.g), blue: CGFloat(glow.b), alpha: 1)
        shadow.shadowBlurRadius = 14
        titleLabel.shadow = shadow
        messageLabel.shadow = shadow
    }

    /// Shows title and artist for 3 s at the start of a song, then fades them out.
    func showTitle(_ title: String, artist: String) {
        titleHide?.cancel()
        guard !lyricsMode else { return }
        titleLabel.stringValue = title
        artistLabel.stringValue = artist
        fade([titleLabel, artistLabel], to: 1, duration: 0.4)
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fade([self.titleLabel, self.artistLabel], to: 0, duration: 0.8)
        }
        titleHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4, execute: hide)
    }

    func showMessage(_ text: String?) {
        if let text {
            messageLabel.stringValue = text
            titleHide?.cancel()
            fade([titleLabel, artistLabel], to: 0, duration: 0.2)
        }
        fade([messageLabel], to: text == nil ? 0 : 1, duration: 0.4)
    }

    func setPaused(_ paused: Bool) {
        renderer?.paused = paused
    }

    /// Debug: saves the next rendered frame as a PNG.
    func snapshot(to url: URL, done: @escaping () -> Void = {}) {
        metalView.framebufferOnly = false
        renderer?.snapshotHandler = { [weak self] background in
            var img = background
            if let self,
               let ctx = CGContext(data: nil, width: background.width, height: background.height,
                                   bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
                ctx.scaleBy(x: CGFloat(background.width) / self.lyricsView.bounds.width,
                            y: CGFloat(background.height) / self.lyricsView.bounds.height)
                if self.lyricsMode {
                    (self.lyricsView.layer?.presentation() ?? self.lyricsView.layer)?.render(in: ctx)
                }
                if let studio = self.studioView, !studio.isHidden,
                   let bitmap = studio.bitmapImageRepForCachingDisplay(in: studio.bounds) {
                    studio.cacheDisplay(in: studio.bounds, to: bitmap)
                    if let panel = bitmap.cgImage { ctx.draw(panel, in: studio.frame) }
                }
                img = ctx.makeImage() ?? background
            }
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
            done()
        }
    }

    /// Live band levels (already delayed to match the speakers), polled every frame.
    func setLevelsProvider(_ provider: @escaping () -> BandLevels?) {
        renderer?.levelsProvider = provider
    }

    /// Debug: saves the lyrics layer (2D render, no Metal background) as a PNG.
    func snapshotLyrics(to url: URL) {
        let size = lyricsView.bounds.size, scale: CGFloat = 1
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        lyricsView.layer?.presentation()?.render(in: ctx) ?? lyricsView.layer?.render(in: ctx)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    func setSceneLyrics(_ timeline: LyricsTimeline?) { renderer?.director.load(timeline) }

    func updateScenePosition(_ position: Double, hostTime: Double) {
        renderer?.director.update(position: position, hostTime: hostTime)
    }

    func register(_ beat: BeatEvent) {
        renderer?.director.register(beat)
        renderer?.lasers.register(beat)
        renderer?.animator.register(beat)
        if lyricsMode, preferences.settings.motion > 0, renderer?.paused == false,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let musicalIntensity = preferences.settings.partyMode && intensity > 0 ? max(0.65, intensity) : intensity
            let response = (0.025 + 0.975 * musicalIntensity * musicalIntensity) * preferences.settings.performanceSettings.motion
                * beat.strength * (0.2 + 0.8 * beat.energy)
            lyricsView.thump(big: beat.isBigHit, intensity: response, duration: tempo.map { min(0.8, 60 / $0 * 0.8) } ?? 0.4)
        }
    }

    func setMusicalResponse(intensity: Float, tempo: Double?) {
        self.intensity = intensity
        self.tempo = tempo
        renderer?.animator.intensity = intensity
        renderer?.animator.tempo = tempo
        let text = tempo.map { "≈\(Int($0.rounded())) BPM  ·  \(intensity < 0.25 ? "Gentle" : intensity < 0.65 ? "Flowing" : "Energetic")" }
            ?? "Listening for the rhythm"
        if preferences.response != text { preferences.response = text }
    }

    func setAnimationStyle(_ style: AnimationStyle) { preferences.responseStyle = style }

    func resetMusicalResponse() {
        renderer?.animator = VisualAnimator()
        renderer?.lasers = LaserChoreographer()
        setMusicalResponse(intensity: 0.12, tempo: nil)
    }

    /// Demo hooks use the same settings path as the studio.
    func configure(_ settings: VisualSettings) { preferences.settings = settings }
    func showStudio() { if studioView?.isHidden == true { toggleStudio() } }

    /// Lyrics replace the cover full screen; the edge glow stays.
    func setLyricsMode(_ on: Bool) {
        lyricsMode = on
        lyricsButton?.title = on ? "Album art · L" : "Lyrics · L"
        renderer?.coverVisible = !on
        lyricsView.isHidden = !on
        if on {
            titleHide?.cancel()
            fade([titleLabel, artistLabel], to: 0, duration: 0.2)
        } else {
            lyricsView.clear()
        }
    }

    func updateLyrics(words: [TimedWord], time: Double) {
        guard lyricsMode else { return }
        lyricsView.update(words: words, palette: renderer?.activePalette ?? PaletteExtractor.fallback, time: time)
    }

    /// A message that disappears after `seconds`.
    func flash(_ text: String, seconds: Double = 2) {
        showMessage(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.messageLabel.stringValue == text else { return }
            self?.showMessage(nil)
        }
    }

    private func apply(_ settings: VisualSettings) {
        renderer?.settings = settings.validated()
        partyButton?.title = settings.partyMode ? "Party ON · P" : "Party · P"
        let effective = settings.performanceSettings
        let half = CGFloat(effective.coverSize / 2) * min(metalView.bounds.width, metalView.bounds.height)
        coverTitleConstraint?.constant = half * 1.25 + 20
        lyricsView.motion = effective.motion
        lyricsView.invalidateColours()
    }

    private func toggleStudio() {
        guard let studioView else { return }
        studioView.isHidden.toggle()
        if studioView.isHidden { window.makeFirstResponder(metalView) }
        NSCursor.setHiddenUntilMouseMoves(false)
        revealControls()
    }

    private func revealControls() {
        controlsHide?.cancel()
        controls.isHidden = false
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Keep controls usable while the pointer rests over them or they have keyboard focus.
            let point = self.window.mouseLocationOutsideOfEventStream
            if self.studioView?.isHidden == false || self.controls.frame.contains(point) ||
                (self.window.firstResponder as? NSView)?.isDescendant(of: self.controls) == true {
                self.revealControls()
            } else {
                self.controls.isHidden = true
                self.renderer?.pointer = .zero
            }
        }
        controlsHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }

    private func fade(_ views: [NSView], to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            views.forEach { $0.animator().alphaValue = alpha }
        }
    }
}
