import AppKit
import ImageIO
import MetalKit
import VisualiserCore

/// Borderless window that can take key focus (needed for Esc and L).
private final class KeyWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onLyricsKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else if event.charactersIgnoringModifiers?.lowercased() == "l", !event.isARepeat { onLyricsKey?() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The full-screen visual: Metal view plus title and message overlays.
final class VisualiserWindowController {
    var onClose: (() -> Void)?
    var onToggleLyrics: (() -> Void)?
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

    var animator: VisualAnimator {
        get { renderer?.animator ?? VisualAnimator() }
        set { renderer?.animator = newValue }
    }

    init(screen: NSScreen) {
        window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(red: 5 / 255, green: 3 / 255, blue: 10 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        metalView = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.preferredFramesPerSecond = max(60, screen.maximumFramesPerSecond)
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
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: content.centerYAnchor, constant: coverHalf * 1.25 + 20),
            artistLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: content.centerYAnchor, constant: coverHalf * 1.25 + 20),
        ])
        window.contentView = content
        window.onEscape = { [weak self] in self?.onClose?() }
        window.onLyricsKey = { [weak self] in self?.onToggleLyrics?() }
    }

    var isAvailable: Bool { renderer != nil }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        metalView.isPaused = false
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func close() {
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
        renderer?.snapshotHandler = { img in
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

    func register(_ beat: BeatEvent) {
        renderer?.animator.register(beat)
        if lyricsMode { lyricsView.thump(big: beat.isBigHit) }
    }

    /// Lyrics replace the cover full screen; the edge glow stays.
    func setLyricsMode(_ on: Bool) {
        lyricsMode = on
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
        lyricsView.update(words: words, palette: renderer?.palette ?? PaletteExtractor.fallback, time: time)
    }

    /// A message that disappears after `seconds`.
    func flash(_ text: String, seconds: Double = 2) {
        showMessage(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.messageLabel.stringValue == text else { return }
            self?.showMessage(nil)
        }
    }

    private func fade(_ views: [NSView], to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            views.forEach { $0.animator().alphaValue = alpha }
        }
    }
}
