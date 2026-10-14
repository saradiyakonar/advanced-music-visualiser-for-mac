import Foundation

public enum VisualScene: String, Codable, CaseIterable, Sendable {
    case aura, orbit, prism, lasers, tunnel, nebula
    public var title: String { rawValue.capitalized }
    public var index: Float { Float(Self.allCases.firstIndex(of: self) ?? 0) }
}

public enum VisualPalette: String, Codable, CaseIterable, Sendable {
    case album, ember, glacier, silver
    public var title: String { rawValue.capitalized }
    public func colours(album: [RGB]) -> [RGB] {
        switch self {
        case .album: return album
        case .ember: return [0xff845e, 0xffcb80, 0xd95079, 0x7f4d9e].map(RGB.init(hex:))
        case .glacier: return [0x84e8df, 0x72a7ff, 0xc2b8ff, 0xe1f7ff].map(RGB.init(hex:))
        case .silver: return [0xdce5ef, 0x8b9bad, 0xf1eae0, 0xabb5c7].map(RGB.init(hex:))
        }
    }
}

public enum VisualPreset: String, CaseIterable, Sendable {
    case drift, immersive, supernova
    public var title: String { rawValue.capitalized }
}

/// Persisted independently of the song's automatic response. Settings never change beat detection.
public struct VisualSettings: Codable, Equatable, Sendable {
    public var scene: VisualScene = .aura
    public var palette: VisualPalette = .album
    public var motion: Float = 0.75
    public var bloom: Float = 0.65
    public var atmosphere: Float = 0.6
    public var particles: Float = 0.35
    public var coverSize: Float = 0.46
    public var speed: Float = 0.6
    public var shockwaves = true
    public var glitch = false
    public var bandHalo = true
    public var hideCover = false
    // Optional storage preserves decoding of looks saved before Party mode existed.
    private var partyEnabled: Bool?
    public var partyMode: Bool {
        get { partyEnabled ?? false }
        set { partyEnabled = newValue ? true : nil }
    }
    public var performanceSettings: Self {
        var value = validated()
        guard partyMode else { return value }
        value.motion = min(1.5, value.motion * 1.45)
        value.bloom = min(1.5, value.bloom * 1.3)
        value.atmosphere = min(1, value.atmosphere * 1.5)
        value.particles = min(1, value.particles * 1.8)
        value.speed = min(1.5, value.speed * 1.35)
        value.coverSize = max(0.28, value.coverSize * 0.72)
        return value
    }
    public init() {}

    public func validated() -> Self {
        var value = self
        func clamp(_ x: Float, _ range: ClosedRange<Float>, _ fallback: Float) -> Float {
            x.isFinite ? min(range.upperBound, max(range.lowerBound, x)) : fallback
        }
        value.motion = clamp(motion, 0...1.5, 0.75)
        value.bloom = clamp(bloom, 0...1.5, 0.65)
        value.atmosphere = clamp(atmosphere, 0...1, 0.6)
        value.particles = clamp(particles, 0...1, 0.35)
        value.coverSize = clamp(coverSize, 0.28...0.62, 0.46)
        value.speed = clamp(speed, 0.1...1.5, 0.6)
        return value
    }

    public static func preset(_ preset: VisualPreset) -> Self {
        var value = Self()
        switch preset {
        case .drift:
            value.motion = 0.3; value.bloom = 0.4; value.particles = 0.18
            value.speed = 0.3; value.shockwaves = false; value.bandHalo = false
        case .immersive: value.scene = .orbit
        case .supernova:
            value.scene = .prism; value.motion = 1.15; value.bloom = 1.1
            value.particles = 0.75; value.speed = 1; value.glitch = true
        }
        return value
    }
}
