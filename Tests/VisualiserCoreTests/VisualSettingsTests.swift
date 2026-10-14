import Foundation
import Testing
@testable import VisualiserCore

@Suite struct VisualSettingsTests {
    @Test func savedLookRoundTrips() throws {
        var settings = VisualSettings.preset(.supernova)
        settings.palette = .glacier
        settings.hideCover = true
        let restored = try JSONDecoder().decode(VisualSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }
    @Test func invalidValuesCannotReachTheRenderer() {
        var settings = VisualSettings()
        settings.motion = .nan; settings.bloom = -5; settings.coverSize = 10; settings.speed = .infinity
        let valid = settings.validated()
        #expect(valid.motion == 0.75)
        #expect(valid.bloom == 0)
        #expect(valid.coverSize == 0.62)
        #expect(valid.speed == 0.6)
    }
    @Test func presetsAndPalettesStayWithinBounds() {
        for preset in VisualPreset.allCases {
            let settings = VisualSettings.preset(preset)
            #expect(settings == settings.validated())
        }
        for palette in VisualPalette.allCases {
            #expect(!palette.colours(album: PaletteExtractor.fallback).isEmpty)
        }
    }
}

@Suite struct PartySettingsTests {
    @Test func oldLooksStillDecodeAndPartyRestoresOriginalLook() throws {
        let original = VisualSettings()
        let oldData = try JSONEncoder().encode(original)
        var settings = try JSONDecoder().decode(VisualSettings.self, from: oldData)
        #expect(!settings.partyMode)
        settings.partyMode = true
        #expect(settings.performanceSettings.motion > original.motion)
        #expect(settings.performanceSettings.coverSize < original.coverSize)
        let saved = try JSONDecoder().decode(VisualSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.partyMode)
        settings.partyMode = false
        #expect(settings == original)
    }
    @Test func partyHonoursDisabledMotionAndBounds() {
        var settings = VisualSettings()
        settings.partyMode = true
        settings.motion = 0
        #expect(settings.performanceSettings.motion == 0)
        settings.motion = .nan
        #expect(settings.performanceSettings.motion.isFinite)
        #expect(settings.performanceSettings == settings.performanceSettings.validated())
    }
}
