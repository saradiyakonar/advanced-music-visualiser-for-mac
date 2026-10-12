# Album Visualiser — Design

Date: 2026-10-12
Owner: Saradiya (steering) · Built by Claude

## Intent

A Mac app for watching music, not making clips. While a song plays in **Spotify** or **Apple Music**, the visualiser fills the screen with that song's **album cover**, pulsing on the beat with a neon glow and glitching on big hits. It was inspired by an Instagram post (arkcurates, "10/10 late night setup") that showed a neon, glitchy, beat-synced visual on a MacBook.

The owner wants it for themselves, on their own MacBook, while music plays in the background. It should feel like the post: dark, neon, and alive to the music, with no setup per song.

## Goals

1. **Follow what's playing.** Detect the current track in Spotify or Apple Music, whichever is playing, and show its album cover in the centre. Swap the cover automatically when the track changes.
2. **Beat sync, automatically.** Listen to the actual audio playing on the Mac, detect beats in real time, and drive the visual from them. No manual BPM, no per-song setup.
3. **The look (picked by the owner from mockups):**
   - **Every beat:** the cover scales up and settles back (a "thump"), a soft neon glow blooms behind it, and a thin neon frame around the screen edge flashes.
   - **Big hits only:** on drops and heavy kicks, the cover glitches. It splits into offset red and cyan copies, and horizontal slices jump sideways, for a moment, then snaps back. Ordinary beats do **not** glitch.
   - **Colours:** glow and frame colours come from the album cover, so each song looks different.
   - **Background:** near-black.
4. **Song title (picked by the owner):** when a new song starts, its title and artist appear below the cover for a few seconds, then fade out. Not shown the rest of the time.
5. **Menu bar app:**
   - An icon in the menu bar with a small menu: *Start visualiser*, *Show on: [display]* (only when more than one display is connected), *Launch at login* (a toggle, on by default, so the shortcut always works; builder's call), *Sync: visuals earlier / later* (see Risk 1; builder's call), *Quit*.
   - A global keyboard shortcut (default **⌃⌥V**) starts it from anywhere.
   - It opens full screen on the chosen display, hiding the Dock and the menu bar. The cursor hides and reappears briefly when the mouse moves.
   - **Esc** closes the visual. The music keeps playing.
   - No Dock icon.
6. **Paused or nothing playing:**
   - Paused: the cover stays, dimmed and still, with a slow "breathing" glow. It picks back up when music resumes.
   - Nothing playing in either app when started: show a short message, "Play something on Spotify or Apple Music".

## Non-goals (this version)

- **YouTube or browser audio.** Removed by the owner.
- **Lyrics.** Deferred to a later version. Lyrics need a separate source for the words and their timing. Neither Spotify nor Apple Music gives other apps that.
- **Spotify Canvas videos** (the looping clips Spotify shows behind some songs). Spotify offers no supported way for other apps to get them. Unofficial methods break Spotify's terms and can stop working. The album cover replaces them.
- The ring-of-frequency-bars style, recording or exporting clips, sharing, accounts, settings sync, App Store release, Windows.
- Auto-starting whenever music plays. Off and not built for now.

## Anti-goals

The owner said nothing specific would bother them and asked to be told when something goes wrong. These are the builder's calls, so the app doesn't fail in obvious ways:

- **No stutter.** The visual should run smoothly (target 60 fps or the display's refresh rate) on the owner's MacBook.
- **No visible lag behind the music.** Beats on screen should land with the beat you hear.
- **Not a battery or heat hog.** Animation only runs while the visualiser is open. The menu bar app sits idle otherwise.
- **No private Apple APIs or unofficial Spotify endpoints.** They break with OS updates or violate terms.

## Constraints and environment

- **Machine:** Apple M5 MacBook, built-in 2560×1664 Retina display, **macOS 27.0**.
- **Spotify** is installed and is the owner's main app, so **build and test Spotify first**. Apple Music ships with macOS and comes second.
- The owner usually listens through **Bluetooth speakers** while the visualiser is on (see Risk 1).
- **Xcode is not installed.** Only the Command Line Tools (`swiftc`, Swift Package Manager) are installed. The build should work without Xcode if possible. See "Risks" below.
- Personal use only. No distribution beyond the owner's own Mac.
- Project folder: `~/Personal/album-visualiser` (git repo).

## How it gets made (builder's calls, not discussed in detail with the owner)

- **Language and UI:** Swift, native macOS app. Menu bar via `NSStatusItem` or SwiftUI `MenuBarExtra`. `LSUIElement` so there's no Dock icon.
- **Rendering:** Metal (e.g. `MTKView`) with fragment shaders for the glow, frame, and glitch (RGB split plus slice offsets), so effects stay smooth at Retina resolution.
- **Audio capture:** prefer a **Core Audio process tap** (macOS 14.2+) on the Spotify or Music process, so only the music is analysed, not notification sounds. Fall back to **ScreenCaptureKit** system audio capture if the tap proves unreliable. Either way, the user grants a one-time macOS permission.
- **Beat detection:** FFT with Accelerate/vDSP. Spectral-flux onset detection weighted to the bass band, with an adaptive threshold. A tempo estimate smooths the pulse between onsets.
  - **"Big hit"** = an onset whose bass energy and loudness jump well above the rolling average of the last few seconds (e.g. mean + k·σ). This way quiet songs still get some glitches, and loud songs don't glitch on every beat.
- **Now playing:**
  - Spotify's AppleScript interface gives track name, artist, player state, and an `artwork url` (an https image URL, so fetching the Spotify cover needs internet).
  - Apple Music's AppleScript gives name, artist, state, and the artwork as raw image data.
  - Listen for the apps' distributed notifications (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`) to catch track changes and pause/play without constant polling. Poll as a backup.
  - If both are playing, pick the one that most recently started playing.
  - Requires the one-time macOS Automation permission for each app.
  - Do **not** use the private MediaRemote framework.
- **Colour extraction:** take 2–3 dominant, saturated colours from the cover for glow and frame. Fall back to the neon pink and purple from the mockups if the cover is grey or dark.
- **Apple Music streamed tracks:** AppleScript often returns no artwork for catalogue tracks that aren't in the library. In that case, look up the cover by title and artist through Apple's public iTunes Search API. It's official, needs no key or sign-in, and is a network call (builder's call).
- **Missing artwork** (e.g. a local Apple Music file with no cover, or a failed lookup): show a built-in neon placeholder graphic with the same effects.
- **Global shortcut:** Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- **Full screen:** a borderless window at screen-saver level on the chosen display, rather than macOS's own full-screen Space, so Esc closes it instantly.

## Reference mockups

The mockups are in `docs/mockups/`. They are HTML fragments with inline JS on a simulated 100 BPM beat, where every 4th beat is a "big hit". They were rendered inside a frame template, but each one runs standalone if you wrap it in a basic HTML page. They are the reference for feel and starting values:

- `1-pulse-styles.html`: style A (pulse and glow), B (glitch hit), C (ring of bars). The owner chose a **mix of A and B**.
- `2-mix-a-b.html`: the owner picked **option 1**, "glow every beat, glitch only on big hits". Option 2, a light glitch on every beat, was rejected.
- `3-song-title.html`: the owner picked **option C**, title and artist shown about 3 s at song start, below the cover, then a fade of about 0.8 s.

Starting values from the mockups (tune from here):
- **Kick envelope:** `(1 − beatPhase)^4`, at full strength on big hits and ×0.6 on normal beats.
- **Cover:** scale `1 + 0.18·kick`.
- **Glow:** behind the cover, blur about 44 px, scale `1.2 + 1.4·kick`, opacity `0.35 + 0.6·kick`.
- **Edge frame:** 2 px, inset about 16 px, rounded, with a neon outer and inner shadow. Opacity `0.25 + 0.75·kick`.
- **Glitch (big hits only):** red and cyan copies offset by up to about 16 px diagonally, plus two horizontal slices about 14 px tall shifted up to about 34 px sideways. It lasts the length of the kick envelope.
- **Fallback colours:** pink `#ff3fd1`, violet `#c13cff`, blue `#5b4bff`, cyan `#00e5ff`.

## What's left to the builder

- Exact animation curves, glow sizes, glitch durations, and title fade timing. Match the feel of the mockups above.
- Beat-detection tuning values and the big-hit threshold.
- Project structure, test approach, and how to package the `.app` without Xcode.
- The placeholder graphic's design (original art, not Spider-Man or any other brand).
- The menu bar icon (a simple original glyph).

## Risks and open technical questions

1. **Audio-to-visual latency (core work, not an extra).** The owner will usually listen through **Bluetooth speakers**. Captured audio arrives before it comes out of a Bluetooth speaker, often 150–300 ms earlier, and the gap varies by speaker. Visuals must be **delayed** to match. Plan:
   - Timestamp every analysis result (beat, big hit, band energy) with its capture time.
   - Render it at capture time plus the output delay.
   - Start from the output device's reported latency (Core Audio device, stream, and safety-offset latency).
   - Bluetooth devices often under-report it, so apply a per-device correction that the owner can nudge.
   - Add a *Sync* control to the menu: "Visuals earlier / later" in about 20 ms steps. Remember it per output device, so it only needs setting once per speaker (builder's call).
   - Re-read the delay whenever the output device changes.
   - Test on a Bluetooth speaker, not only the built-in speakers.
2. **Building without Xcode.** Swift Package Manager can build the binary, and the `.app` bundle and `Info.plist` can be assembled by a script. macOS remembers permissions (audio capture, Automation) per code signature. An ad-hoc signature that changes every build can make macOS re-ask for permission after each rebuild. Mitigation: a stable self-signed local signing identity. If that fails, ask the owner to install Xcode.
3. **Process tap availability on macOS 27.** It's a newer API. If it misbehaves, switch to ScreenCaptureKit audio, which needs the Screen Recording permission instead.
4. **Spotify AppleScript.** It's long-standing but not formally guaranteed. If `artwork url` stops working, fall back to the Spotify Web API (needs a free developer app key and a sign-in) to fetch the cover by track ID.

## Later (not this version)

- Lyrics, beat-synced where possible, from a lyrics source with timing.
- Extra looks (ring of bars, light glitch on every beat), selectable from the menu.
- Auto-start when music plays.

---

## v2 changes (2026-10-12, after first use)

### Edge glow: Lumn-style (owner supplied `~/Desktop/lumn-demo.mp4`)
- **Shape:** a thick, soft glow hugging all four screen edges, replacing the thin neon frame line. The inner boundary ripples in uneven, slowly moving blobs, and the glow brightens toward white right at the edge.
- **Colours:** two album colours, primary (about 60%) and secondary (about 40%), blended along the edges and slowly drifting. No complementary colours.
- **Music sync:** glow thickness and brightness swell with each beat and with bass.

### Visual tuning (done)
- **Cover size:** half the shorter screen dimension.
- **Beats:** a 40 ms eased attack, then a gentle decay.
- **Between beats:** continuous motion from delayed bass/mid levels.
- **Tilt:** alternates direction each beat.

### Lyrics (owner supplied `~/Desktop/verci-hero.mp4` as the look)
- **Trigger:** the **L** key toggles lyrics mode while the visualiser is open. Lyrics replace the album cover full screen, and the edge glow stays. Lyrics mode persists across songs until L is pressed again. It's off when the visualiser opens.
- **Source:** LRCLIB (`https://lrclib.net/api/get`, falling back to `/api/search`), which gives line-timed lyrics. If nothing is found, pressing L shows "No lyrics for this song" for 2 s and stays on the cover.
- **Timing:** each line's words are spread across the line's time, weighted by length. The playback position comes from the player's AppleScript `player position`, extrapolated on the host clock and shifted by the output delay.
- **Look:**
  - black background
  - up to 3 words of the current line stacked, newest at the bottom
  - older words shrink and fade
  - a new line clears the stack
  - a mix of heavy, bold, regular and italic weights
  - some words in a solid colour block with white text
  - a slight 3D tilt
  - icons for some common words (Apple's built-in symbols or emoji)
  - colours from the album palette, cycling over time
  - the current word thumps on the beat
