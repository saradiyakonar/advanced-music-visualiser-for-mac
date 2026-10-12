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

    @Test func greyImageFallsBack() {
        #expect(PaletteExtractor.extract(from: image { _, _ in (128, 128, 128) }) == PaletteExtractor.fallback)
    }

    @Test func darkImageFallsBack() {
        #expect(PaletteExtractor.extract(from: image { _, _ in (10, 5, 20) }) == PaletteExtractor.fallback)
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
