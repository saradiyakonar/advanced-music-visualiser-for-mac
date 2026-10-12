# Album Visualiser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app that shows the current Spotify/Apple Music album cover full screen, pulsing and glowing on every beat and glitching on big hits, with beats detected live from the music's audio.

**Architecture:** One Swift package with two targets.
- `VisualiserCore` is a library of pure, unit-tested logic: beat detection, latency compensation, animation state, palette extraction, and now-playing parsing and arbitration.
- `AlbumVisualiser` is the executable. It holds the macOS glue: menu bar, hotkey, Core Audio process tap, AppleScript now-playing, the full-screen window, and the Metal renderer.
- `scripts/build-app.sh` wraps the release binary in an ad-hoc-signed `.app` bundle, because Xcode isn't installed.

**Tech Stack:** Swift 6.4 / SwiftPM, Swift Testing, AppKit, Metal (shaders compiled at runtime from a source string, since the `metal` CLI is unavailable), Accelerate/vDSP, Core Audio process taps (macOS 14.2+), NSAppleScript, Carbon hotkeys, ServiceManagement.

**Spec:** `docs/superpowers/specs/2026-10-12-album-visualiser-design.md`. Mockups are in `docs/mockups/`.

## Global Constraints

- Target macOS 14.2+ (`platforms: [.macOS("14.2")]`). Develop and test on macOS 27.0, Apple M5.
- No Xcode: build with `swift build`, test with `swift test` (Swift Testing, `import Testing`). Shaders are compiled with `MTLDevice.makeLibrary(source:options:)`.
- No private frameworks (no MediaRemote) and no unofficial Spotify endpoints. Allowed network calls: the Spotify `artwork url`, and `https://itunes.apple.com/search`.
- Never launch Spotify or Music as a side effect. Check `NSRunningApplication` before sending any AppleScript.
- `LSUIElement = true` (no Dock icon). Bundle id `com.saradiya.albumvisualiser`.
- Info.plist usage strings:
  - `NSAudioCaptureUsageDescription` = "Album Visualiser listens to the music playing on your Mac to sync the visuals to the beat."
  - `NSAppleEventsUsageDescription` = "Album Visualiser asks Spotify and Music what song is playing so it can show the album cover."
- Hotkey default ⌃⌥V. Esc closes the visual. Music keeps playing.
- No-music copy, exactly: "Play something on Spotify or Apple Music".
- Fallback palette: `#ff3fd1`, `#c13cff`, `#5b4bff`, `#00e5ff`.
- Animation runs only while the visualiser window is open.
- Spotify is built and tested before Apple Music.

## Review Focus

1. **Spotify or Music not running, or quitting while the visual is open.** It should show the no-music message, never relaunch the app, never crash. Covered by a `NowPlayingArbiter` test (Task 5) plus the running-app guard in Task 7.
2. **Artwork missing, slow, or offline.** Keep showing the previous cover until the new one loads. Fall back to the placeholder if loading fails. Never show a blank centre. Covered by the `ArtworkResolver` fallback test (Task 5).
3. **Silence, very quiet tracks, or speech.** No glitch storms, no NaNs, no divide-by-zero. Covered by the `BeatDetector` silence and quiet-track tests (Task 3).
4. **Output device changes while open** (a Bluetooth speaker connects or drops). The delay is re-read and the per-device offset is applied. Covered by the `SyncOffsetStore` per-device test (Task 4) and the device-change listener in Task 7.
5. **Chosen display disconnected.** Fall back to the main screen. Covered by the `DisplayChooser` test (Task 8).

---

## File Structure

```
Package.swift
Sources/VisualiserCore/
  KickEnvelope.swift        envelope + per-frame VisualFrame from beat events (mockup formulas)
  BeatDetector.swift        FFT, band energies, spectral-flux onsets, big-hit flag
  LatencyCompensator.swift  delays timestamped events by output latency + user offset
  SyncOffsetStore.swift     per-output-device offset persistence (injected KeyValueStore)
  NowPlaying.swift          TrackInfo, PlayerState, AppleScript output parsing, NowPlayingArbiter
  ArtworkResolver.swift     iTunes Search JSON parsing, fallback ordering
  PaletteExtractor.swift    dominant saturated colours from a CGImage, fallback palette
  DisplayChooser.swift      pick NSScreen-like target by id with fallback
Sources/AlbumVisualiser/
  main.swift / AppDelegate.swift   app lifecycle, wiring (AppController)
  MenuBarController.swift          status item + menu
  HotKey.swift                     Carbon global hotkey
  AudioTapCapture.swift            Core Audio process tap → Float32 mono buffers + host time
  OutputLatency.swift              default output device id/uid/name + reported latency, change listener
  NowPlayingService.swift          NSAppleScript for Spotify/Music + distributed notifications + polling
  ArtworkLoader.swift              fetch URL/raw data, iTunes lookup, decode CGImage
  VisualiserWindow.swift           borderless full-screen window, Esc, cursor hide, title overlay
  MetalRenderer.swift              MTKView delegate, uniforms
  Shaders.swift                    Metal shader source string
  LaunchAtLogin.swift              SMAppService.mainApp
Resources/Info.plist
scripts/build-app.sh
Tests/VisualiserCoreTests/*.swift
```

---

### Task 1: Package, app bundle script, menu bar skeleton

**Files:**
- Create: `Package.swift`, `Sources/VisualiserCore/KickEnvelope.swift` (stub type only), `Sources/AlbumVisualiser/main.swift`, `Sources/AlbumVisualiser/AppDelegate.swift`, `Sources/AlbumVisualiser/MenuBarController.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `Tests/VisualiserCoreTests/SmokeTests.swift`
- Modify: `.gitignore` (add `build/`)

**Interfaces:**
- Produces: `MenuBarController(onStart: () -> Void, onQuit: () -> Void)`, `func rebuildMenu()`. `scripts/build-app.sh` outputs `build/Album Visualiser.app` and copies it to `~/Applications/Album Visualiser.app`.

- [ ] **Step 1:** Write `SmokeTests.swift` with `@Test func coreLinks() { #expect(VisualiserCore.version == "0.1.0") }`.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL (no target).
- [ ] **Step 3:** Write `Package.swift` with targets `VisualiserCore`, executable `AlbumVisualiser` (depends on the core), and test target `VisualiserCoreTests`. Add `public enum VisualiserCore { public static let version = "0.1.0" }`. Add an AppKit app with `NSApplication.shared.setActivationPolicy(.accessory)` and a status item using SF Symbol `waveform.circle`, with a menu of *Start visualiser* (disabled stub) and *Quit*.
- [ ] **Step 4:** Write `build-app.sh`:
  1. `swift build -c release`
  2. Make `Contents/MacOS` and `Contents/Resources`.
  3. Copy the binary and `Resources/Info.plist` (with `CFBundleExecutable`, `CFBundleIdentifier`, `LSUIElement`, both usage strings, and `LSMinimumSystemVersion` 14.2).
  4. Run `codesign --force --sign - --timestamp=none`.
  5. Run `plutil -lint`.
  6. Copy to `~/Applications`.
- [ ] **Step 5:** Run `swift test && scripts/build-app.sh && codesign -dv "build/Album Visualiser.app" 2>&1 | grep Identifier`. Expected: test passes, `Identifier=com.saradiya.albumvisualiser`.
- [ ] **Step 6:** Launch with `open "build/Album Visualiser.app"`. Confirm the process is running (`pgrep -x AlbumVisualiser`), then `pkill -x AlbumVisualiser`.
- [ ] **Step 7:** Commit: `feat: package skeleton, menu bar app, bundle script`.

### Task 2: Kick envelope and per-frame visual state

**Files:**
- Create/Modify: `Sources/VisualiserCore/KickEnvelope.swift`
- Test: `Tests/VisualiserCoreTests/KickEnvelopeTests.swift`

**Interfaces:**
- Produces:
  - `public struct BeatEvent: Sendable, Equatable { public var time: Double; public var strength: Float; public var isBigHit: Bool }`. `time` is in seconds on the host clock, and `strength` is in 0...1.
  - `public struct VisualFrame: Equatable { coverScale, glowScale, glowOpacity, frameOpacity, glitchAmount: Float; slicesVisible: Bool; beatSerial: Int }`.
  - `public struct VisualAnimator { public init(beatDecay: Double = 0.6); public mutating func register(_ e: BeatEvent); public func frame(at t: Double, paused: Bool) -> VisualFrame }`.

The envelope and formulas come from the mockups. `phase = clamp((t − lastBeat.time) / beatDecay, 0, 1)` and `env = (1 − phase)^4`. Then `kick = env · (isBigHit ? 1 : 0.6) · max(strength, 0.5)`.
- `coverScale = 1 + 0.18·kick`
- `glowScale = 1.2 + 1.4·kick`
- `glowOpacity = 0.35 + 0.6·kick`
- `frameOpacity = 0.25 + 0.75·kick`
- `glitchAmount = isBigHit ? env : 0`, zeroed when below 0.08
- `slicesVisible = isBigHit && glitchAmount > 0.35`

When paused: kick = 0 and glitch = 0. `glowOpacity = 0.25 + 0.1·sin(2π·t/4)` gives the breathing, and `coverScale = 1`.

- [ ] **Step 1: Write the failing tests:**
  - `restingFrameHasNoKick`: with no events, `frame(at: 10, paused: false)` has `coverScale == 1`, `glowOpacity == 0.35`, and `glitchAmount == 0`.
  - `normalBeatPeaksWithoutGlitch`: register `BeatEvent(time: 1, strength: 1, isBigHit: false)`. At t=1, `coverScale ≈ 1.108` (±0.001) and `glitchAmount == 0`.
  - `bigHitGlitches`: a big hit at t=1. At t=1, `coverScale ≈ 1.18`, `glitchAmount == 1`, and `slicesVisible == true`. At t=1.6, `glitchAmount == 0`.
  - `envelopeDecays`: the value at t=1.15 is less than at t=1.0 and greater than at t=1.5.
  - `pausedBreathesAndIgnoresBeats`: a big hit at t=1 with `paused: true` at t=1 gives `coverScale == 1` and `glitchAmount == 0`, and `glowOpacity` in 0.15...0.35.
- [ ] **Step 2:** `swift test --filter KickEnvelopeTests`. Expected: FAIL.
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** `swift test --filter KickEnvelopeTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: kick envelope and visual frame state`.

### Task 3: Beat detector

**Files:**
- Create: `Sources/VisualiserCore/BeatDetector.swift`
- Test: `Tests/VisualiserCoreTests/BeatDetectorTests.swift` (with a helper `Synth` that generates test signals)

**Interfaces:**
- Consumes: `BeatEvent` (Task 2).
- Produces:
  - `public struct BandLevels: Sendable { bass, mid, treble: Float }`, normalised 0...1 against a rolling peak.
  - `public final class BeatDetector { public init(sampleRate: Double, fftSize: Int = 1024, hopSize: Int = 512); public func process(_ samples: UnsafeBufferPointer<Float>, startTime: Double) -> [BeatEvent]; public private(set) var levels: BandLevels }`.

**Algorithm (decided here):**
1. For each hop, apply a Hann window and run a vDSP real FFT to get magnitudes.
2. Bands: bass 30–150 Hz, mid 150–2000 Hz, treble 2000–8000 Hz.
3. Onset function = half-wave rectified spectral flux, weighted 0.6 bass and 0.4 full band.
4. Adaptive threshold = median of the last 1 s of flux × 1.5 + 0.02·(rolling peak of flux). Fire an onset on a local maximum above the threshold, with a minimum gap of 0.25 s.
5. Silence gate: skip a hop if its RMS < 1e-4.
6. `strength` = flux / rolling peak, clamped to 0...1.
7. **Big hit:** bass energy of the onset hop > mean + 1.5·σ of bass energy over the last 4 s, **and** RMS > the 4 s mean RMS. Also require at least 1.0 s since the last big hit.
8. Event `time` = `startTime + hopIndexOffset/sampleRate`.

- [ ] **Step 1: Write the failing tests** (44.1 kHz; a "kick" is a 60 Hz sine burst of 80 ms with exponential decay; the background is low-level noise at amplitude 0.01):
  - `detectsSteadyKicks`: a 120 BPM kick track for 8 s. Detected beats after the first 1 s match the expected times within 30 ms, with ≥ 90% recall and ≤ 10% extra.
  - `silenceProducesNothing`: 5 s of zeros gives no events, and `levels` contains no NaN.
  - `steadyToneProducesNothing`: a constant 440 Hz sine for 5 s gives ≤ 1 event.
  - `accentedKicksAreBigHits`: 120 BPM where every 4th kick has 3× amplitude. ≥ 75% of the accented kicks after the first 4 s are `isBigHit`, and ≤ 10% of the normal kicks are.
  - `quietTrackStillGetsBigHits`: the same accented track scaled by 0.05 still yields big hits on ≥ 50% of the accents.
  - `uniformLoudTrackRarelyGlitches`: 120 BPM, all kicks equal and loud, gives big hits on ≤ 15% of beats.
  - `chunkingDoesNotChangeResults`: feeding the 120 BPM track in 512-sample chunks versus 1 337-sample chunks gives the same event count (±1).
- [ ] **Step 2:** `swift test --filter BeatDetectorTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Keep an internal ring buffer so any chunk size works.
- [ ] **Step 4:** `swift test --filter BeatDetectorTests`. Expected: PASS. Tune the constants above only if a test fails, and record any change in a code comment.
- [ ] **Step 5:** Commit: `feat: real-time beat detector with big-hit detection`.

### Task 4: Latency compensation and per-device sync offset

**Files:**
- Create: `Sources/VisualiserCore/LatencyCompensator.swift`, `Sources/VisualiserCore/SyncOffsetStore.swift`
- Test: `Tests/VisualiserCoreTests/LatencyTests.swift`

**Interfaces:**
- Produces:
  - `public protocol KeyValueStore: AnyObject { func double(forKey: String) -> Double?; func set(_ v: Double, forKey: String) }`, with an `extension UserDefaults` conformance (returning nil when the key is absent) and an `InMemoryStore` used in tests.
  - `public final class SyncOffsetStore { public init(store: KeyValueStore); public func offset(forDeviceUID: String, isBluetooth: Bool) -> Double; public func nudge(deviceUID: String, isBluetooth: Bool, by: Double) }`. The default is 0.0 for wired and built-in, and **0.12 s** for Bluetooth (an extra correction on top of the reported latency). Each nudge step is ±0.02. Clamp to −0.3...0.6. Key: `"sync.offset.<uid>"`.
  - `public final class LatencyCompensator { public var delay: Double; public init(delay: Double = 0); public func enqueue(_ e: [BeatEvent]); public func due(upTo now: Double) -> [BeatEvent] }`. Events come out once `e.time + delay <= now`, in order, and their `time` is rewritten to `e.time + delay`.

- [ ] **Step 1: Write the failing tests:**
  - `holdsEventsUntilDelayElapses`: with a delay of 0.2 and an event at t=1.0, `due(upTo: 1.1)` is empty, and `due(upTo: 1.2)` returns one event with `time == 1.2`.
  - `releasesInOrderOnce`: three events. A second `due` call returns nothing more.
  - `bluetoothDefaultOffset`: a fresh store gives 0.12 for Bluetooth and 0.0 for wired.
  - `nudgePersistsPerDevice`: nudging device "A" by +0.02 twice gives `offset("A") ≈ 0.16` (Bluetooth). Device "B" is unchanged. A new `SyncOffsetStore` on the same backing store returns 0.16.
  - `offsetIsClamped`: nudging by +1.0 gives 0.6.
- [ ] **Step 2:** `swift test --filter LatencyTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter LatencyTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: latency compensation and per-device sync offsets`.

### Task 5: Now-playing model, arbitration, artwork resolution

**Files:**
- Create: `Sources/VisualiserCore/NowPlaying.swift`, `Sources/VisualiserCore/ArtworkResolver.swift`
- Test: `Tests/VisualiserCoreTests/NowPlayingTests.swift`

**Interfaces:**
- Produces:
  - `public enum PlayerApp: String, Sendable { case spotify, music }`
  - `public enum PlayerState: Sendable { case playing, paused, stopped }`
  - `public struct TrackInfo: Equatable, Sendable { app: PlayerApp; id: String; title: String; artist: String; album: String; state: PlayerState; artworkURL: URL? }`
  - `public enum AppleScriptParser { public static func parse(_ output: String, app: PlayerApp) -> TrackInfo? }`. The AppleScript returns the fields joined by the unit separator `\u{1F}` in the order `state, id, title, artist, album, artworkURL`, with an empty string for a missing value. A `state` of `"stopped"`, or a missing title, gives `nil`.
  - `public final class NowPlayingArbiter { public func update(_ info: TrackInfo?, from app: PlayerApp, at time: Double); public var current: TrackInfo? }`. Prefer the app that most recently entered `.playing`. If none is playing, keep the most recently paused track as `.paused`. If both are nil or stopped, `current` is nil.
  - `public enum ArtworkSource: Equatable { case url(URL), musicRawData, itunesLookup(title: String, artist: String), placeholder }`
  - `public enum ArtworkResolver { public static func candidates(for t: TrackInfo, hasRawData: Bool) -> [ArtworkSource]; public static func parseITunesSearch(_ data: Data) -> URL?; public static func itunesSearchURL(title: String, artist: String) -> URL }`
    - Spotify order: `[.url, .placeholder]`.
    - Music order: `[.musicRawData if hasRawData, .itunesLookup, .placeholder]`.
    - `parseITunesSearch` takes the first result's `artworkUrl100` and replaces `100x100` with `1000x1000`.
    - The search URL is `https://itunes.apple.com/search?term=<artist title>&entity=song&limit=1`, percent-encoded.

- [ ] **Step 1: Write the failing tests:**
  - `parsesSpotifyOutput`: `"playing\u{1F}spotify:track:1\u{1F}Song\u{1F}Artist\u{1F}Album\u{1F}https://i.scdn.co/image/x"` gives the matching `TrackInfo`.
  - `stoppedOrEmptyIsNil`: `"stopped\u{1F}..."` gives nil, and `""` gives nil.
  - `mostRecentPlayingWins`: Spotify plays at t=1 and Music plays at t=2, so current is Music. Music pauses at t=3, so current is Spotify.
  - `appQuitClearsIt`: Spotify playing, then `update(nil, from: .spotify, at: 2)`, gives current nil.
  - `pausedKeptWhenNothingPlays`: Spotify paused only gives current with `state == .paused`.
  - `spotifyCandidates` and `musicCandidatesWithAndWithoutRawData` check the orders above. The last candidate is always `.placeholder`.
  - `parsesITunesSearch`: a sample JSON with `artworkUrl100` ".../100x100bb.jpg" gives ".../1000x1000bb.jpg". `{"resultCount":0,"results":[]}` gives nil. Garbage gives nil.
- [ ] **Step 2:** `swift test --filter NowPlayingTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test --filter NowPlayingTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: now-playing parsing, arbitration, artwork resolution`.

### Task 6: Palette extraction and display choice

**Files:**
- Create: `Sources/VisualiserCore/PaletteExtractor.swift`, `Sources/VisualiserCore/DisplayChooser.swift`
- Test: `Tests/VisualiserCoreTests/PaletteAndDisplayTests.swift`

**Interfaces:**
- Produces:
  - `public struct RGB: Equatable, Sendable { r, g, b: Float }`
  - `public enum PaletteExtractor { public static let fallback: [RGB]` (the four hex colours in the Global Constraints) `; public static func extract(from image: CGImage, count: Int = 3) -> [RGB] }`
    1. Downsample to 32×32.
    2. Quantise hue into 24 bins, ignoring pixels with HSV saturation < 0.35 or value < 0.25.
    3. Rank bins by pixel count × saturation.
    4. Return the top `count` colours at full brightness (V = 1, saturation boosted to ≥ 0.7).
    5. If fewer than 2 bins qualify, return `fallback`.
  - `public enum DisplayChooser { public static func choose(preferredID: UInt32?, available: [UInt32], main: UInt32) -> UInt32 }`. Return the preferred display if it's available, otherwise main.

- [ ] **Step 1: Write the failing tests:**
  - `extractsDominantHues`: an image that's half pure red and half pure blue gives 2 colours whose dominant channels are red and blue.
  - `greyImageFallsBack`: a mid-grey image gives `fallback`.
  - `darkImageFallsBack`: a near-black image gives `fallback`.
  - `preferredDisplayUsedWhenPresent`, and `missingDisplayFallsBackToMain`.
- [ ] **Step 2:** `swift test --filter PaletteAndDisplayTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Draw the image into a `CGContext` with a known RGBA8 layout.
- [ ] **Step 4:** `swift test --filter PaletteAndDisplayTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: album palette extraction and display fallback`.

### Task 7: System services (audio tap, output latency, now playing, artwork loading)

**Files:**
- Create: `Sources/AlbumVisualiser/AudioTapCapture.swift`, `OutputLatency.swift`, `NowPlayingService.swift`, `ArtworkLoader.swift`
- Add: a hidden debug flag. `AlbumVisualiser --diagnose` prints now-playing info, the output device and its latency, and detected beats for 10 s, then exits.

**Interfaces:**
- Consumes: `BeatDetector`, `TrackInfo`, `AppleScriptParser`, `NowPlayingArbiter`, `ArtworkResolver`.
- Produces:
  - `final class AudioTapCapture { init(); func start(processID: pid_t, onSamples: @escaping (UnsafeBufferPointer<Float>, Double) -> Void) throws; func stop() }`. It creates a `CATapDescription(stereoMixdownOfProcesses: [AudioObjectID])` for the player's audio process object, then a private aggregate device containing the tap, and an IO proc that mixes to mono. The `Double` passed to `onSamples` is the buffer start time in host seconds (from `AudioTimeStamp.mHostTime` → seconds).
  - `struct OutputDeviceInfo { uid: String; name: String; isBluetooth: Bool; reportedLatency: Double }`, plus `enum OutputLatency { static func current() -> OutputDeviceInfo?; static func observeChanges(_ handler: @escaping () -> Void) }`.
    - `reportedLatency` = (device latency + safety offset + stream latency + buffer frame size) / sample rate.
    - `isBluetooth` comes from the transport type (`kAudioDeviceTransportTypeBluetooth` / `BluetoothLE`).
  - `final class NowPlayingService { var onChange: ((TrackInfo?) -> Void)?; func start(); func stop(); func playerPID(for: PlayerApp) -> pid_t? }`
    - Listen for `com.spotify.client.PlaybackStateChanged` and `com.apple.Music.playerInfo` on `DistributedNotificationCenter`, and poll every 2 s as a backup.
    - Run AppleScript only if `NSRunningApplication.runningApplications(withBundleIdentifier:)` is non-empty (`com.spotify.client`, `com.apple.Music`).
  - `final class ArtworkLoader { func load(for: TrackInfo, completion: @escaping (CGImage?) -> Void) }`. It walks `ArtworkResolver.candidates` in order with a 5 s timeout each, caches by `TrackInfo.id`, and calls back on the main thread.
  - AppleScript (Spotify):

    ```applescript
    tell application "Spotify"
      set s to player state as string
      if s is "stopped" then return "stopped"
      set t to current track
      return s & (ASCII character 31) & (id of t) & (ASCII character 31) & (name of t) & (ASCII character 31) & (artist of t) & (ASCII character 31) & (album of t) & (ASCII character 31) & (artwork url of t)
    end tell
    ```

    Music uses the same shape, with `persistent ID` for the id and an empty artwork URL. Raw data comes from `raw data of artwork 1 of current track`, fetched separately and wrapped in `try`.

- [ ] **Step 1:** Implement the four files and the `--diagnose` mode.
- [ ] **Step 2:** `scripts/build-app.sh`. Expected: builds and signs.
- [ ] **Step 3:** With a track playing in Spotify, run `"build/Album Visualiser.app/Contents/MacOS/AlbumVisualiser" --diagnose` after approving the Automation and Audio Capture prompts. Expected:
  - a `track:` line with the right title and artist
  - an `output:` line naming the device and its latency
  - `beat` lines roughly every 0.4–0.6 s for typical music, with some `BIG` lines
  - no lines at all when Spotify is paused
- [ ] **Step 4:** Quit Spotify and rerun. Expected: `track: none`, and Spotify does **not** relaunch.
- [ ] **Step 5:** Commit: `feat: audio tap, output latency, now-playing and artwork services`.

### Task 8: Full-screen visualiser window and Metal renderer

**Files:**
- Create: `Sources/AlbumVisualiser/VisualiserWindow.swift`, `MetalRenderer.swift`, `Shaders.swift`

**Interfaces:**
- Consumes: `VisualAnimator`, `VisualFrame`, `RGB`, `DisplayChooser`.
- Produces:
  - `final class VisualiserWindowController { init(screen: NSScreen); var onClose: (() -> Void)?; func show(); func close(); func setArtwork(_ img: CGImage?, palette: [RGB]); func showTitle(_ title: String, artist: String); func showMessage(_ text: String?); func setPaused(_ p: Bool); var animator: VisualAnimator }`
  - `MetalRenderer: NSObject, MTKViewDelegate`. Each frame it calls `animator.frame(at: CACurrentMediaTime(), paused:)` and draws one full-screen pass.

**Shader** (single fragment pass, uniforms from `VisualFrame` plus palette plus aspect ratio):
- Near-black background `#05030a`.
- Cover texture quad, centred, with side = 36% of the screen's shorter dimension × `coverScale`, and 1.5% corner rounding.
- Glow: a soft rounded-rect falloff around the cover in `palette[0]`. Radius scales with `glowScale`, intensity is `glowOpacity`.
- Edge frame: a rounded rect inset 1.5% of the shorter dimension, about 2 pt line plus an exponential falloff in `palette[1]`, alpha `frameOpacity`.
- Glitch when `glitchAmount > 0`: sample the cover at ±(0.012 · glitchAmount) UV offsets for the red and cyan copies (screen blend). When `slicesVisible`, offset UV.x by ±0.04·glitchAmount in 2 horizontal bands, each about 2.5% tall, whose y positions are seeded by `beatSerial`.

**Window and overlays:**
- The window is a borderless `NSWindow` covering `screen.frame`, at level `.screenSaver`, with `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`. It calls `NSApp.presentationOptions = [.hideDock, .hideMenuBar]` while open.
- **Esc** (keyCode 53) calls `onClose`.
- The cursor hides after 2 s without movement and shows again on mouse move.
- **Title overlay:** an `NSTextField` pair under the cover, white with a glow shadow in `palette[0]`. Title semibold 28 pt, artist 17 pt at 65% white. It fades in over 0.4 s, stays 3 s, and fades out over 0.8 s.
- **Message overlay:** the same style, centred, used for the no-music copy.
- **Placeholder artwork:** drawn in code. An original concentric neon ring and diamond glyph in the fallback palette on a dark background, with no brand references.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Add a debug flag `--demo` that opens the window on the main screen with the placeholder art and feeds a synthetic 100 BPM beat (every 4th beat a big hit), mirroring the mockup.
- [ ] **Step 3:** `scripts/build-app.sh && open "build/Album Visualiser.app" --args --demo`. Capture with `screencapture -x /tmp/claude-501/demo.png` at least twice, about 0.3 s apart. Expected: a centred cover, glow, and frame visible, with the scale differing between captures. Esc closes the window.
- [ ] **Step 4:** Commit: `feat: full-screen Metal visualiser window`.

### Task 9: Wire it together: menu, hotkey, launch at login, sync controls

**Files:**
- Create: `Sources/AlbumVisualiser/HotKey.swift`, `LaunchAtLogin.swift`, `AppController.swift`
- Modify: `AppDelegate.swift`, `MenuBarController.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `final class AppController { func startVisualiser(); func stopVisualiser() }`.

**Behaviour:**
- **Menu:** *Start visualiser ⌃⌥V*, *Show on ▸* (one item per screen, only when there's more than one screen, with a checkmark on the current one), *Sync ▸* (*Visuals earlier*, *Visuals later*, *Reset*, plus a disabled info line such as "JBL Flip · +140 ms"), *Launch at login* (toggle, checked), *Quit*.
  - The chosen display id is persisted under `display.preferred`.
  - Launch at login is enabled on first run via `SMAppService.mainApp.register()`. Failures are logged and the item is left unchecked.
- **Hotkey:** Carbon `RegisterEventHotKey` for ⌃⌥V. It toggles the visualiser open or closed.
- **On start:**
  1. Resolve now playing. If none, show the window with the message "Play something on Spotify or Apple Music" and keep listening.
  2. Otherwise start `AudioTapCapture` on the player's PID.
  3. Feed `BeatDetector` → `LatencyCompensator` (delay = `reportedLatency + SyncOffsetStore.offset`) → `animator.register` on a 60 Hz main-thread timer via `due(upTo: CACurrentMediaTime())`.
- **On track change:** load the artwork. Keep the old artwork until the new one is ready. Compute the palette, call `showTitle`, and re-target the tap if the player app changed.
- **On pause:** `setPaused(true)`.
- **On output device change:** recompute the delay.
- **On stop:** stop the tap, the timer, and the window. Nothing keeps running except the menu bar item and the hotkey.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift test` (all pass) and `scripts/build-app.sh`.
- [ ] **Step 3:** Manual end-to-end check with Spotify playing:
  - Press ⌃⌥V. The cover appears with its title, pulses on the beat, and glitches only on drops.
  - Skip a track. The cover and title change.
  - Pause. The cover dims and breathes.
  - Esc closes it, and Spotify keeps playing.
  - Repeat with Apple Music.
  - With nothing playing, the message appears.
- [ ] **Step 4:** Check idle CPU with the window closed. `ps -o %cpu -p $(pgrep -x AlbumVisualiser)` should be < 1%.
- [ ] **Step 5:** Commit: `feat: wire menu, hotkey, sync and launch at login`.

### Task 10: README

**Files:** Create `README.md`, covering build and install (`scripts/build-app.sh`), the permissions you'll be asked for, the Sync menu for Bluetooth speakers, the `--demo` and `--diagnose` flags, and the known limitation that ad-hoc-signed rebuilds may re-ask for permissions.

- [ ] **Step 1:** Write it.
- [ ] **Step 2:** Commit: `docs: README`.
