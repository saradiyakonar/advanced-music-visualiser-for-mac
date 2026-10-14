# Album Visualiser

A menu bar app for macOS. While a song plays in **Spotify** or **Apple Music**, it fills the screen with the album cover:
- **Song-aware motion:** starts gently, learns an approximate tempo, and weights movement by measured audio energy. Quiet or slow songs breathe; energetic tracks move more.
- **Big hits:** an album-colored pressure wave expands across the screen, with a zoom and light bloom in both modes. Strong hits are spaced out so dense beats do not become a strobe.
- **Lyrics:** recognizable cover details surround a soft, dark stage for kinetic words. The artwork drifts with the music and mouse.
- **New song:** the title shows for a few seconds, then fades.

Beats are detected live from the music's audio.

## Build and install

Requires macOS 14.2+ and the Xcode Command Line Tools. Full Xcode isn't needed.

```bash
scripts/build-app.sh
```

This builds `build/Album Visualiser.app` and copies it to `~/Applications`. Open it from there, and a waveform icon appears in the menu bar.

## Use

- **⌃⌥V** or the menu's *Start visualiser* opens it full screen. **Esc** closes it, and the music keeps playing.
- **L** switches between artwork and lyrics (when available). Move the mouse to reveal playback controls. **Space** pauses playback; **← / →** change tracks. **[ / ]** adjust lyric timing.
- **V** opens **Visual studio**. **1–6** switch between **Aura** (light curtains), **Orbit** (elliptical trails), **Prism** (mirrored artwork), **Lasers** (sweeping beams), **Tunnel** (travelling rings), and **Nebula** (colour clouds). Scene transitions blend smoothly.
- Choose **Match song**, **Gentle**, or **Punchy** response. The displayed BPM is an onset-based estimate; syncopated music can produce half/double-time estimates. Uncertain estimates are hidden.
- Start with **Drift**, **Immersive**, or **Supernova**, then adjust motion, bloom, artwork atmosphere, stardust, drift speed, and cover size. Choose album colors, Ember, Glacier, or Silver.
- Toggle the three-band halo, drop waves, glitches, or hide the cover for an uninterrupted atmosphere. The halo represents bass/mid/treble energy, not a full frequency spectrum.
- Changes are remembered on this Mac. **Save my look / Recall look** keeps one favorite independently of current adjustments; **Surprise me** changes the scene and colors without raising your motion setting. **Reset** restores the default look.
- **Esc** dismisses the studio first, then closes the visualiser.
- macOS **Reduce Motion** suppresses the shockwave, zoom, parallax, and lyric pops.
- *Show on* (only with more than one display) picks the screen.
- *Sync → Visuals earlier / later* shifts the visuals in 20 ms steps. Use it if they land before or after the beat you hear. The setting is saved per speaker. Bluetooth speakers start with a +120 ms correction.
- *Launch at login* is on by default, so the shortcut always works.

## Permissions

macOS asks once for each:
- **Control Spotify / Music:** to read the current song and its cover.
- **Audio capture:** to listen to the music for beat detection.

Builds are ad-hoc signed, so macOS may ask again after a rebuild. If permissions get stuck, reset them in System Settings → Privacy & Security.

## Development

```bash
scripts/test.sh
```

- `scripts/test.sh` runs the unit tests in `Tests/`. It passes the Swift Testing plugin path the Command Line Tools need.
- `AlbumVisualiser --diagnose` prints the current track, the output device and its latency, and 10 s of detected beats. Run it via `open --stdout out.txt "build/Album Visualiser.app" --args --diagnose`, so permissions apply to the app.
- `AlbumVisualiser --demo` plays the visual on a synthetic 120 BPM beat. Add `--snapshot-dir <dir>` to save frames and quit.
- Demo options: `--scene aura|orbit|prism|lasers|tunnel|nebula`, `--light-palette album|ember|glacier|silver`, `--bpm 70 --energy 0.1` for a quiet passage, `--party` for Party mode, `--maximal` for Supernova, `--studio` for the customization panel, and `--lyrics` for sample words. Demo settings do not overwrite your saved configuration.

Design: `docs/superpowers/specs/`. Plan: `docs/superpowers/plans/`. Reference mockups: `docs/mockups/`.

### Music and lyric scenes

Timed lyrics now drive ten background effect families in both album and lyrics views: branching lightning strikes with rolling afterglow, fire/embers, water, stars, bursts of hearts, drifting particles, snowflakes, flowers, rain, and celebration confetti. Cues are prepared locally using English whole-word and phrase rules, including a few extinguishing-fire phrases. This is a curated vocabulary, not general language understanding; other languages and unmatched phrases keep the normal audio-driven scene.

Effects enter on a nearby strong beat (waiting at most 450 ms), last across a phrase, and fade smoothly. Line-level lyric timing is used; exact sung-word alignment is not promised. Repeated imagery returns to the same effect family. Seeking and track changes clear old cues. Lyrics are fetched automatically through the existing LRCLIB service even when the cover is visible; unavailable lyrics leave audio effects working normally.

Rising beat energy draws the scene inward, and detected drops expand it outward. The existing Motion and Atmosphere controls scale the effects; pause, zero motion, and macOS Reduce Motion suppress the animated lyric overlays. No sound effects or rapid full-screen flashes are added.

**Party mode:** press **P**, click **Party · P** on the bottom controls, or use **Visual studio → Party mode → Fill the room**. Party mode boosts motion, light, particle density and speed while shrinking the cover. Turning it off restores the original settings; saved looks from earlier versions still load. Zero Motion and Reduce Motion remain respected. EDM and dance music drive the visuals through live beats and drops even without lyrics. Lasers and Tunnel are especially suited to these rhythms. Strong hits can launch confetti in Party mode. Lyric strikes and heart bursts have a 1.4-second cooldown and are rendered as geometry, not emoji; themed words no longer add a duplicate lyric emoji/icon.

Lasers now use paired stage heads: each detected beat alternates their sweep direction, strong hits open the fans wider, and every eight onsets advances between twin fans, crossed beams, and an overhead curtain. Head movements ease over 160 ms; bass drives brightness and drops widen the beams and haze. No new onsets means no new lighting cues.
