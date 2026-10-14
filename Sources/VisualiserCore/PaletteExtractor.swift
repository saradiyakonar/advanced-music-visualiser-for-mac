import CoreGraphics
import Foundation

public struct RGB: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(r: Float((hex >> 16) & 0xff) / 255, g: Float((hex >> 8) & 0xff) / 255, b: Float(hex & 0xff) / 255)
    }
}

/// Picks the album cover's dominant saturated colours for the glow and frame.
public enum PaletteExtractor {
    /// Neon pink, violet, blue, cyan (from the mockups), used for grey or dark covers.
    public static let fallback: [RGB] = [RGB(hex: 0xff3fd1), RGB(hex: 0xc13cff), RGB(hex: 0x5b4bff), RGB(hex: 0x00e5ff)]

    private static let side = 32
    private static let hueBins = 24
    private static let minSaturation: Float = 0.2
    private static let minValue: Float = 0.2

    /// For black-and-white or very dark covers: soft whites and silvers (the cover's
    /// own "colours"), never stock neon.
    public static let neutral: [RGB] = [RGB(r: 0.96, g: 0.96, b: 0.98), RGB(r: 0.80, g: 0.82, b: 0.86),
                                        RGB(r: 0.90, g: 0.90, b: 0.90)]
    private static let minBinShare: Float = 0.02 // a bin needs 2% of pixels to count

    public static func extract(from image: CGImage, count: Int = 4) -> [RGB] {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drew: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return fallback }

        var counts = [Int](repeating: 0, count: hueBins)
        var satSum = [Float](repeating: 0, count: hueBins)
        var valSum = [Float](repeating: 0, count: hueBins)
        var hueX = [Float](repeating: 0, count: hueBins) // circular mean of hue per bin
        var hueY = [Float](repeating: 0, count: hueBins)

        for i in stride(from: 0, to: px.count, by: 4) {
            let (h, s, v) = hsv(Float(px[i]) / 255, Float(px[i + 1]) / 255, Float(px[i + 2]) / 255)
            guard s >= minSaturation, v >= minValue else { continue }
            let bin = min(hueBins - 1, Int(h * Float(hueBins)))
            counts[bin] += 1
            satSum[bin] += s
            valSum[bin] += v
            hueX[bin] += cos(h * 2 * .pi)
            hueY[bin] += sin(h * 2 * .pi)
        }

        let total = Float(side * side)
        let ranked = (0..<hueBins)
            .filter { Float(counts[$0]) / total >= minBinShare }
            .sorted { Float(counts[$0]) * satSum[$0] > Float(counts[$1]) * satSum[$1] }
        guard let top = ranked.first else { return neutral }

        // Keep the cover's real hue and roughly its saturation; only lift brightness
        // enough to glow on black.
        func colour(_ bin: Int) -> (h: Float, s: Float, v: Float) {
            var hue = atan2(hueY[bin], hueX[bin]) / (2 * .pi)
            if hue < 0 { hue += 1 }
            let n = Float(counts[bin])
            let sat = min(1, max(0.35, satSum[bin] / n * 1.15))
            let val = min(1, max(0.85, valSum[bin] / n * 1.25))
            return (hue, sat, val)
        }

        // One strong colour: build shades of it rather than falling back to stock neon.
        if ranked.count == 1 {
            let (h, s, v) = colour(top)
            let wrap = { (x: Float) in x < 0 ? x + 1 : (x >= 1 ? x - 1 : x) }
            return Array([
                rgb(h: h, s: s, v: v),
                rgb(h: wrap(h - 0.035), s: s * 0.85, v: v),
                rgb(h: wrap(h + 0.035), s: s, v: v * 0.8),
                rgb(h: h, s: s * 0.5, v: min(1, v * 1.1)),
            ].prefix(max(count, 1)))
        }

        return ranked.prefix(count).map { bin in
            let (h, s, v) = colour(bin)
            return rgb(h: h, s: s, v: v)
        }
    }

    /// Average colour of the cover's outer border (≈6% each side): what to fill the
    /// screen with around the art so it blends into its own background.
    public static func borderColour(from image: CGImage) -> RGB {
        let n = 48, ring = 3
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return RGB(r: 0.02, g: 0.01, b: 0.04) }
        var r: Float = 0, g: Float = 0, b: Float = 0, count: Float = 0
        for y in 0..<n {
            for x in 0..<n where x < ring || x >= n - ring || y < ring || y >= n - ring {
                let i = (y * n + x) * 4
                r += Float(px[i]); g += Float(px[i + 1]); b += Float(px[i + 2]); count += 1
            }
        }
        return RGB(r: r / count / 255, g: g / count / 255, b: b / count / 255)
    }

    /// The colour opposite on the hue wheel, same saturation and brightness.
    public static func complement(of c: RGB) -> RGB {
        let (h, s, v) = hsv(c.r, c.g, c.b)
        return rgb(h: (h + 0.5).truncatingRemainder(dividingBy: 1), s: s, v: v)
    }

    /// Colours the edge frame flows through: each palette colour followed by its
    /// complement, at most six.
    public static func cycleColors(from palette: [RGB]) -> [RGB] {
        let base = palette.isEmpty ? fallback : palette
        return Array(base.flatMap { [$0, complement(of: $0)] }.prefix(6))
    }

    private static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let s = mx == 0 ? 0 : d / mx
        var h: Float = 0
        if d > 0 {
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, s, mx)
    }

    private static func rgb(h: Float, s: Float, v: Float) -> RGB {
        let i = Int(h * 6) % 6
        let f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}
