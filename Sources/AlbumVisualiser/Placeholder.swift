import CoreGraphics
import VisualiserCore

/// Original fallback cover for tracks without artwork: concentric neon rings around a
/// diamond, in the fallback palette, on a dark background.
enum Placeholder {
    static let image: CGImage = {
        let side = 1024
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(side)
        let colors = PaletteExtractor.fallback.map { CGColor(red: CGFloat($0.r), green: CGFloat($0.g), blue: CGFloat($0.b), alpha: 1) }

        let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [CGColor(red: 0.10, green: 0.02, blue: 0.20, alpha: 1),
                                     CGColor(red: 0.02, green: 0.01, blue: 0.05, alpha: 1)] as CFArray,
                            locations: [0, 1])!
        ctx.drawRadialGradient(bg, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                               endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.75, options: [])

        let c = CGPoint(x: s / 2, y: s / 2)
        for (i, r) in [0.42, 0.33, 0.24].enumerated() {
            ctx.setStrokeColor(colors[i % colors.count])
            ctx.setLineWidth(s * 0.012)
            ctx.setShadow(offset: .zero, blur: s * 0.04, color: colors[i % colors.count])
            ctx.strokeEllipse(in: CGRect(x: c.x - s * r, y: c.y - s * r, width: s * r * 2, height: s * r * 2))
        }

        let d = s * 0.13
        ctx.setFillColor(colors[3])
        ctx.setShadow(offset: .zero, blur: s * 0.06, color: colors[3])
        ctx.move(to: CGPoint(x: c.x, y: c.y + d))
        ctx.addLine(to: CGPoint(x: c.x + d, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y - d))
        ctx.addLine(to: CGPoint(x: c.x - d, y: c.y))
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()!
    }()
}
