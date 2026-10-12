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

            let iconSide = wordStyle.icon == nil ? 0 : fontSize * 0.62
            let gap = wordStyle.icon == nil ? 0 : fontSize * 0.22
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        var p = CATransform3DIdentity
        p.m34 = -1 / 900
        stage.sublayerTransform = p
        stage.frame = bounds
        layer?.addSublayer(stage)
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
    func thump(big: Bool) {
        let newestIndex = layers.keys.max()
        for (i, l) in layers {
            let base = l.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
            let amount: CGFloat = (i == newestIndex ? 0.14 : 0.06) * (big ? 1.6 : 1)
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
