# Album Visualiser

A menu bar app for macOS. While a song plays in **Spotify** or **Apple Music**, it fills the screen with the album cover:
- **Every beat:** the cover pulses and a neon glow blooms behind it.
- **Big hits:** the cover glitches.
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
- `AlbumVisualiser --demo` plays the visual on a fake 100 BPM beat. Add `--snapshot-dir <dir>` to save frames and quit.

Design: `docs/superpowers/specs/`. Plan: `docs/superpowers/plans/`. Reference mockups: `docs/mockups/`.
