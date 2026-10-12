import AppKit
import QuartzCore
import VisualiserCore

/// Word-by-word kinetic lyrics (look from the reference video): up to three words of
/// the current line stacked, newest at the bottom and largest, older ones shrinking and
/// fading; mixed weights, some words in a colour block, icons for common words, slight
/// 3D tilt, colours from the album cycling over time.
final class LyricsView: NSView {
    private final class WordLayer: CALayer {
        let word: TimedWord
        let wordStyle: WordStyle
        let block = CALayer()
        let text = CATextLayer()
        let icon = CALayer()
        var size: CGSize = .zero
        var colourStep = Int.min

        init(word: TimedWord, fontSize: CGFloat, scale: CGFloat) {
            self.word = word
            wordStyle = WordStyler.style(for: word.text, index: word.index)
            super.init()

            let weight: NSFont.Weight = switch wordStyle.weight {
            case .heavy: .heavy
            case .bold: .bold
            case .semibold: .semibold
            case .regular: .regular
            }
            var font = NSFont.systemFont(ofSize: fontSize, weight: weight)
            if wordStyle.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let str = NSAttributedString(string: word.text, attributes: [.font: font])
            let textSize = str.size()
            let padX = wordStyle.block ? fontSize * 0.14 : 0
            let padY = wordStyle.block ? fontSize * 0.04 : 0

            let hasMark = wordStyle.icon != nil || wordStyle.emoji != nil
            let iconSide = hasMark ? fontSize * 0.62 : 0
            let gap = hasMark ? fontSize * 0.22 : 0
            size = CGSize(width: iconSide + gap + textSize.width + padX * 2, height: textSize.height + padY * 2)
            bounds = CGRect(origin: .zero, size: size)

            if let name = wordStyle.icon, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: iconSide, weight: .bold)
                let sized = img.withSymbolConfiguration(cfg) ?? img
                icon.contents = sized.layerContents(forContentsScale: scale)
                icon.contentsGravity = .resizeAspect
                icon.frame = CGRect(x: 0, y: (size.height - iconSide) / 2, width: iconSide, height: iconSide)
                icon.contentsScale = scale
                addSublayer(icon)
            } else if let e = wordStyle.emoji {
                // Emoji keep their own colours; drawn as text, not tinted.
                let el = CATextLayer()
                el.string = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: iconSide * 0.92)])
                el.alignmentMode = .center
                el.contentsScale = scale
                el.frame = CGRect(x: 0, y: (size.height - iconSide * 1.15) / 2, width: iconSide * 1.1, height: iconSide * 1.15)
                addSublayer(el)
            }

            block.frame = CGRect(x: iconSide + gap, y: 0, width: textSize.width + padX * 2, height: size.height)
            block.cornerRadius = fontSize * 0.04
            block.isHidden = !wordStyle.block
            addSublayer(block)

            text.string = str
            text.contentsScale = scale
            text.frame = CGRect(x: iconSide + gap + padX, y: padY, width: textSize.width + 2, height: textSize.height)
            addSublayer(text)

            // A slight, word-specific 3D tilt.
            let r = Double((word.index &* 7919) % 100) / 100
            var t = CATransform3DMakeRotation(CGFloat((r - 0.5) * 0.35), 0, 1, 0)
            t = CATransform3DRotate(t, CGFloat((0.5 - r) * 0.12), 1, 0, 0)
            transform = t
        }

        override init(layer: Any) {
            let l = layer as! WordLayer
            word = l.word
            wordStyle = l.wordStyle
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) { fatalError() }

        func apply(colour: NSColor) {
            if wordStyle.block {
                block.backgroundColor = colour.cgColor
                setTextColour(.white)
            } else {
                setTextColour(colour)
            }
            tintIcon(colour)
        }

        private func setTextColour(_ c: NSColor) {
            guard let s = text.string as? NSAttributedString else { return }
            let m = NSMutableAttributedString(attributedString: s)
            m.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: m.length))
            text.string = m
        }

        private func tintIcon(_ c: NSColor) {
            // Mask the symbol so it takes the word's colour.
            // The symbol becomes the mask, so only its shape shows, filled with the colour.
            if icon.mask == nil {
                guard let symbol = icon.contents else { return }
                let mask = CALayer()
                mask.contents = symbol
                mask.contentsGravity = .resizeAspect
                mask.contentsScale = icon.contentsScale
                mask.frame = icon.bounds
                icon.mask = mask
                icon.contents = nil
            }
            icon.backgroundColor = c.cgColor
        }
    }

    private var layers: [Int: WordLayer] = [:]
    private let stage = CALayer()
    /// Shown when no words are on screen (intros, solos, breaks), so it's never empty.
    private let note = CALayer()
    private var noteColourStep = Int.min

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        var p = CATransform3DIdentity
        p.m34 = -1 / 900
        stage.sublayerTransform = p
        stage.frame = bounds
        layer?.addSublayer(stage)

        if let img = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 200, weight: .bold)) {
            let mask = CALayer()
            mask.contents = img.layerContents(forContentsScale: 2)
            mask.contentsGravity = .resizeAspect
            note.mask = mask
        }
        note.opacity = 0
        layer?.addSublayer(note)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stage.frame = bounds
    }

    /// Shows `words` (oldest first). Call every frame; only changes are animated.
    func update(words: [TimedWord], palette: [RGB], time: Double) {
        let scale = window?.backingScaleFactor ?? 2
        let h = bounds.height
        let wanted = Set(words.map(\.index))

        // Music note in the gaps: album colour (cycling like the words), fades in and out.
        let side = h * 0.26
        note.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        note.mask?.frame = note.bounds
        note.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let noteStep = Int((time / WordStyler.colourPeriod).rounded(.down))
        if noteStep != noteColourStep {
            noteColourStep = noteStep
            let c = WordStyler.colour(forWordIndex: 0, time: time, palette: palette)
            note.backgroundColor = CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        }
        let showNote: Float = words.isEmpty ? 0.9 : 0
        if note.opacity != showNote {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = note.presentation()?.opacity ?? note.opacity
            f.toValue = showNote
            f.duration = 0.35
            note.add(f, forKey: "fade")
            note.opacity = showNote
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        // Words that left the stack fade away.
        for (i, l) in layers where !wanted.contains(i) {
            layers[i] = nil
            l.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { l.removeFromSuperlayer() }
        }

        // Sizes: newest largest; a word alone on screen is larger still.
        let newestSize = h * (words.count == 1 ? 0.17 : 0.14)
        let sizes = words.indices.map { i -> CGFloat in
            let age = words.count - 1 - i
            return newestSize * pow(0.72, CGFloat(age))
        }

        for w in words where layers[w.index] == nil {
            let l = WordLayer(word: w, fontSize: newestSize, scale: scale)
            l.opacity = 0
            stage.addSublayer(l)
            layers[w.index] = l
            // Entrance: pop in from slightly larger.
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 1.3
            pop.toValue = 1
            pop.duration = 0.22
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(pop, forKey: "pop")
        }

        // Stack top to bottom, centred as a group.
        let gap = h * 0.02
        let heights = words.indices.map { i in (layers[words[i].index]?.size.height ?? 0) * sizes[i] / newestSize }
        var y = bounds.midY + (heights.reduce(0, +) + gap * CGFloat(max(words.count - 1, 0))) / 2
        let step = Int((time / WordStyler.colourPeriod).rounded(.down))
        for (i, w) in words.enumerated() {
            guard let l = layers[w.index] else { continue }
            let s = sizes[i] / newestSize
            let age = words.count - 1 - i
            y -= heights[i]
            l.position = CGPoint(x: bounds.midX, y: y + heights[i] / 2)
            l.setValue(s, forKeyPath: "transform.scale")
            l.opacity = Float([1.0, 0.62, 0.32][min(age, 2)])
            l.zPosition = CGFloat(-age) * 40
            y -= gap
            if l.colourStep != step {
                l.colourStep = step
                let c = WordStyler.colour(forWordIndex: w.index, time: time, palette: palette)
                l.apply(colour: NSColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1))
            }
        }
        CATransaction.commit()
    }

    /// Beat pulse: every visible word bumps, the newest most; big hits bump harder.
    func thump(big: Bool, intensity: Float = 1) {
        if note.opacity > 0 {
            let n = CAKeyframeAnimation(keyPath: "transform.scale")
            let amount = (big ? 0.22 : 0.12) * CGFloat(0.45 + 0.55 * intensity)
            n.values = [1, 1 + amount, 1]
            n.keyTimes = [0, 0.18, 1]
            n.duration = big ? 0.42 : 0.3
            note.add(n, forKey: "thump")
        }

        let newestIndex = layers.keys.max()
        for (i, l) in layers {
            let base = l.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
            let amount: CGFloat = (i == newestIndex ? 0.14 : 0.06) * (big ? 1.6 : 1) * CGFloat(0.45 + 0.55 * intensity)
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [base, base * (1 + amount), base]
            a.keyTimes = [0, 0.18, 1]
            a.duration = big ? 0.42 : 0.3
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            l.add(a, forKey: "thump")
        }
    }

    func clear() {
        layers.values.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
    }
}
