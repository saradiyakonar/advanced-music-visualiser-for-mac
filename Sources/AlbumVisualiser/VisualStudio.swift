import AppKit
import SwiftUI
import VisualiserCore

final class VisualPreferences: ObservableObject {
    @Published var settings: VisualSettings {
        didSet {
            if persistChanges, let data = try? JSONEncoder().encode(settings.validated()) { defaults.set(data, forKey: "visual.studio.v1") }
            onChange?(settings.validated())
        }
    }
    @Published var responseStyle: AnimationStyle = .auto {
        didSet { if oldValue != responseStyle { onResponseStyle?(responseStyle) } }
    }
    var onResponseStyle: ((AnimationStyle) -> Void)?
    @Published var response = "Listening for the rhythm"
    @Published var hasSavedLook: Bool
    @Published var savedNotice = ""
    var onChange: ((VisualSettings) -> Void)?
    var onClose: (() -> Void)?
    private let defaults: UserDefaults
    private let persistChanges: Bool
    private var demoFavorite: VisualSettings?

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true) {
        self.persistChanges = persistChanges
        self.defaults = defaults
        settings = (persistChanges ? defaults.data(forKey: "visual.studio.v1") : nil)
            .flatMap { try? JSONDecoder().decode(VisualSettings.self, from: $0) }?.validated() ?? VisualSettings()
        hasSavedLook = persistChanges && defaults.data(forKey: "visual.studio.favorite") != nil
    }

    func saveLook() {
        guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
        if persistChanges { defaults.set(data, forKey: "visual.studio.favorite") } else { demoFavorite = settings }
        hasSavedLook = true
        savedNotice = "Your look is saved on this Mac."
    }

    func recallLook() {
        if !persistChanges, let demoFavorite { settings = demoFavorite; savedNotice = "Your saved look is back."; return }
        guard let data = defaults.data(forKey: "visual.studio.favorite"),
              let look = try? JSONDecoder().decode(VisualSettings.self, from: data) else { return }
        settings = look.validated()
        savedNotice = "Your saved look is back."
    }

    func shuffle() {
        settings.scene = VisualScene.allCases.randomElement() ?? .aura
        settings.palette = VisualPalette.allCases.randomElement() ?? .album
        settings.atmosphere = Float.random(in: 0.4...0.9)
        settings.particles = Float.random(in: 0.15...0.7)
        savedNotice = "A fresh mix. Motion stays at your chosen level."
    }
}

struct VisualStudio: View {
    @ObservedObject var model: VisualPreferences
    private let accent = Color(red: 0.65, green: 0.83, blue: 0.94)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MAKE IT YOURS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(accent)
                    Text("Visual studio").font(.system(size: 26, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button { model.onClose?() } label: { Image(systemName: "xmark").padding(5) }
                    .buttonStyle(.plain).accessibilityLabel("Close visual studio")
            }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.response).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                        Text("Motion follows the music. These controls shape the look.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    section("Party mode · P") {
                        Toggle("Fill the room", isOn: $model.settings.partyMode)
                            .toggleStyle(.switch)
                        Text("Bigger beat pulses, brighter effects, a smaller cover. Works without lyrics.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    section("Response") {
                        Picker("Response", selection: $model.responseStyle) {
                            Text("Match song").tag(AnimationStyle.auto)
                            Text("Gentle").tag(AnimationStyle.soft)
                            Text("Punchy").tag(AnimationStyle.energetic)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    section("Start with a mood") {
                        HStack {
                            ForEach(VisualPreset.allCases, id: \.self) { preset in
                                Button(preset.title) { model.settings = .preset(preset) }
                                    .frame(maxWidth: .infinity)
                            }
                        }.controlSize(.small)
                    }
                    section("Scene · keys 1–6") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(VisualScene.allCases, id: \.self) { scene in
                                Button { model.settings.scene = scene } label: {
                                    HStack {
                                        Text(scene.title).font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        Text("\(Int(scene.index) + 1)").font(.system(size: 10, design: .monospaced)).opacity(0.6)
                                    }.padding(11).frame(maxWidth: .infinity)
                                        .background(model.settings.scene == scene ? accent.opacity(0.25) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.settings.scene == scene ? accent : Color.clear))
                                }.buttonStyle(.plain).accessibilityLabel("\(scene.title) scene")
                                    .accessibilityValue(model.settings.scene == scene ? "Selected" : "")
                            }
                        }
                        Text(sceneDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    section("Light palette") {
                        Picker("Light palette", selection: $model.settings.palette) {
                            ForEach(VisualPalette.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    VStack(spacing: 13) {
                        dial("Motion", value: $model.settings.motion, range: 0...1.5)
                        dial("Bloom", value: $model.settings.bloom, range: 0...1.5)
                        dial("Artwork atmosphere", value: $model.settings.atmosphere)
                        dial("Stardust", value: $model.settings.particles)
                        dial("Drift speed", value: $model.settings.speed, range: 0.1...1.5)
                        dial("Cover size", value: $model.settings.coverSize, range: 0.28...0.62)
                    }
                    Divider().overlay(.white.opacity(0.06))
                    VStack(spacing: 12) {
                        Toggle("Bass / mid / treble halo", isOn: $model.settings.bandHalo)
                        Toggle("Drop shockwaves", isOn: $model.settings.shockwaves)
                        Toggle("Glitch on big hits", isOn: $model.settings.glitch)
                        Toggle("Hide cover · atmosphere only", isOn: $model.settings.hideCover)
                    }.toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                    HStack {
                        Button("Surprise me", systemImage: "shuffle") { model.shuffle() }
                        Spacer()
                        Button("Reset") { model.settings = VisualSettings(); model.savedNotice = "" }
                    }.controlSize(.small)
                    HStack {
                        Button("Save my look") { model.saveLook() }
                        Button("Recall look") { model.recallLook() }.disabled(!model.hasSavedLook)
                    }.controlSize(.small)
                    if !model.savedNotice.isEmpty {
                        Text(model.savedNotice).font(.system(size: 11)).foregroundStyle(accent)
                    }
                    Text("V  studio     P  party     L  lyrics\nSpace  play / pause\n← →  tracks     Esc  close")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineSpacing(5)
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        Text("Reduce Motion is on in macOS. Moving effects are held still.")
                            .font(.system(size: 11)).foregroundStyle(accent)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
        }
        .foregroundStyle(Color(red: 0.91, green: 0.94, blue: 0.97))
        .tint(accent)
        .background(Color(red: 0.035, green: 0.055, blue: 0.09).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var sceneDescription: String {
        switch model.settings.scene {
        case .aura: return "Slow curtains of album-colored light."
        case .orbit: return "Orbital paths wrapped around the music."
        case .prism: return "A mirrored tunnel made from the album itself."
        case .lasers: return "Beat-driven fans, crossed beams, and overhead curtains."
        case .tunnel: return "Fly through rings that expand with every kick."
        case .nebula: return "Clouds of colour with bright dancing particles."
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func dial(_ title: String, value: Binding<Float>, range: ClosedRange<Float> = 0...1) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small).accessibilityLabel(title)
        }
    }
}
