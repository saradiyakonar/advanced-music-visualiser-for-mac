import CoreGraphics
import Testing
@testable import VisualiserCore

@Suite struct PaletteAndDisplayTests {
    /// Builds a 64×64 image; `color(x, y)` returns RGB bytes.
    func image(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let w = 64, h = 64
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = color(x, y)
                let i = (y * w + x) * 4
                px[i] = r; px[i + 1] = g; px[i + 2] = b
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func extractsDominantHues() {
        let img = image { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) }
        let p = PaletteExtractor.extract(from: img)
        #expect(p.count == 2)
        #expect(p.contains { $0.r > 0.9 && $0.g < 0.4 && $0.b < 0.4 })
        #expect(p.contains { $0.b > 0.9 && $0.r < 0.4 && $0.g < 0.4 })
    }

    @Test func greyCoverGlowsInSoftWhites() {
        let p = PaletteExtractor.extract(from: image { x, _ in x < 32 ? (128, 128, 128) : (230, 230, 230) })
        #expect(p != PaletteExtractor.fallback)
        #expect(p.count >= 2)
        for c in p {
            #expect(max(c.r, c.g, c.b) - min(c.r, c.g, c.b) < 0.12) // near-neutral
            #expect(max(c.r, c.g, c.b) > 0.7)                        // bright enough to glow
        }
    }

    @Test func nearBlackCoverAlsoGetsSoftWhites() {
        let p = PaletteExtractor.extract(from: image { _, _ in (10, 5, 20) })
        #expect(p != PaletteExtractor.fallback)
        #expect(p.allSatisfy { max($0.r, $0.g, $0.b) > 0.7 })
    }

    @Test func mutedCoverKeepsItsRealColour() {
        // Muted teal: should stay teal and muted, not become neon cyan.
        let p = PaletteExtractor.extract(from: image { _, _ in (70, 110, 110) })
        let c = p[0]
        #expect(c.g > c.r && c.b > c.r)                              // teal
        let sat = (max(c.r, c.g, c.b) - min(c.r, c.g, c.b)) / max(c.r, c.g, c.b)
        #expect(sat < 0.6)                                           // not pushed to neon
        #expect(max(c.r, c.g, c.b) > 0.75)                           // brightened to glow
    }

    @Test func fallbackMatchesSpecColours() {
        let f = PaletteExtractor.fallback
        #expect(f.count == 4)
        #expect(f[0] == RGB(hex: 0xff3fd1))
        #expect(f[1] == RGB(hex: 0xc13cff))
        #expect(f[2] == RGB(hex: 0x5b4bff))
        #expect(f[3] == RGB(hex: 0x00e5ff))
    }

    @Test func preferredDisplayUsedWhenPresent() {
        #expect(DisplayChooser.choose(preferredID: 7, available: [1, 7], main: 1) == 7)
    }

    @Test func missingDisplayFallsBackToMain() {
        #expect(DisplayChooser.choose(preferredID: 9, available: [1, 7], main: 1) == 1)
        #expect(DisplayChooser.choose(preferredID: nil, available: [1, 7], main: 1) == 1)
    }
}

@Suite struct ColourCycleTests {
    @Test func complementOfRedIsCyan() {
        let c = PaletteExtractor.complement(of: RGB(r: 1, g: 0, b: 0))
        #expect(c.r < 0.05 && c.g > 0.95 && c.b > 0.95)
    }

    @Test func cycleInterleavesPaletteAndComplements() {
        let red = RGB(r: 1, g: 0, b: 0), blue = RGB(r: 0, g: 0, b: 1)
        let cycle = PaletteExtractor.cycleColors(from: [red, blue])
        #expect(cycle.count == 4)
        #expect(cycle[0] == red)
        #expect(cycle[2] == blue)
        #expect(cycle[1].g > 0.95 && cycle[1].b > 0.95) // cyan, red's complement
        #expect(cycle[3].r > 0.95 && cycle[3].g > 0.95) // yellow, blue's complement
    }

    @Test func cycleIsCappedAtSix() {
        #expect(PaletteExtractor.cycleColors(from: PaletteExtractor.fallback).count == 6)
    }
}

@Suite struct RicherPaletteTests {
    func image(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let w = 64, h = 64
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = color(x, y); let i = (y * w + x) * 4
            px[i] = r; px[i + 1] = g; px[i + 2] = b
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func singleHueCoverGetsShadesOfItsOwnColour() {
        let p = PaletteExtractor.extract(from: image { _, _ in (220, 40, 40) })
        #expect(p != PaletteExtractor.fallback)
        #expect(p.count >= 3)
        #expect(Set(p.map { "\($0.r),\($0.g),\($0.b)" }).count == p.count) // all different
        for c in p { #expect(c.r >= c.g && c.r >= c.b) }                  // all still red-family
    }

    @Test func fourColourCoverGivesFour() {
        let p = PaletteExtractor.extract(from: image { x, y in
            switch (x < 32, y < 32) {
            case (true, true): (255, 0, 0)
            case (false, true): (0, 200, 0)
            case (true, false): (0, 0, 255)
            case (false, false): (255, 220, 0)
            }
        })
        #expect(p.count == 4)
    }
}

@Suite struct BorderColourTests {
    func image(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        let w = 64, h = 64
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = color(x, y); let i = (y * w + x) * 4
            px[i] = r; px[i + 1] = g; px[i + 2] = b
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func readsTheColourAroundTheEdge() {
        // Dark green frame around a bright red centre: the background colour is the green.
        let img = image { x, y in (x < 6 || x > 57 || y < 6 || y > 57) ? (20, 90, 40) : (250, 20, 20) }
        let c = PaletteExtractor.borderColour(from: img)
        #expect(abs(c.r - 20 / 255) < 0.06)
        #expect(abs(c.g - 90 / 255) < 0.06)
        #expect(abs(c.b - 40 / 255) < 0.06)
    }

    @Test func plainImageGivesItsColour() {
        let c = PaletteExtractor.borderColour(from: image { _, _ in (200, 200, 210) })
        #expect(abs(c.b - 210 / 255) < 0.03)
    }
}
