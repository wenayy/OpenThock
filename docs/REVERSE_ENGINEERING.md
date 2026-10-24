# How Klack works — reverse-engineering notes

These notes record what was observed about [Klack](https://tryklack.com) (a $4.99
macOS menu-bar app, App Store id `6446206067`) and how OpenThock reproduces each
behavior. Everything here comes from **public** material: the tryklack.com landing page
JavaScript bundle (`/assets/routes-*.js`, `/assets/changelog-*.js`,
`/assets/faqs-*.js`), fetched on 2026-10-24. The Klack app binary was **not**
available on this machine and was not analyzed. None of Klack's audio was downloaded,
and none ships with this project.

Each item is tagged **Observed** (read directly from Klack's code or text),
**Inferred** (a strong conclusion from what was observed), or **Design** (our own choice).

---

## 1. Every key has its own recorded sound (and a separate release sound)

**Observed:** the landing page's "Preview" player loads one file per key and direction:

```js
fetch(`${CDN}/sounds/preview/${set}/${soundKey}-down.wav`)
fetch(`${CDN}/sounds/preview/${set}/${soundKey}-up.wav`)
```

The preview phrase is a list of `{soundKey, key}` pairs:

| key | soundKey |
|-----|----------|
| K   | 37 |
| L   | 38 |
| A   | 30 |
| C   | 46 |
| Space | 57 |
| P   | 25 |
| R   | 19 |
| E   | 18 |
| V   | 47 |
| I   | 23 |
| W   | 17 |
| ⌘   | 3675 |
| ⏎   | 28 |

**Observed (FAQ):** *"Each switch set consist of over 100 audio files that need to be
recorded and mastered individually."*

**Conclusion:** the forum post is right. The sound is **not** randomly picked from a
pool. Each physical key maps to its own fixed recording, and press and release are
separate recordings. Hitting `E` always plays `18-down.wav`, and letting go always
plays `18-up.wav`. About 50+ keys × 2 directions gives the "over 100 files".

## 2. The key numbering is libuiohook / PC set-1 scancodes

**Inferred:** `30 = A`, `57 = Space`, `28 = Enter`, and `3675 = 0x0E5B = VC_META_L`
are exactly libuiohook's virtual key codes. These are based on IBM PC set-1 scancodes
and are also the codes Mechvibes packs use. They are *not* macOS `kVK_*` codes (on
macOS, `A` is 0).

**Design:** OpenThock names sound files with the same codes (`Sources/OpenThock/KeyMap.swift`
maps macOS `kVK_*` to them). The pack layout therefore matches Klack's, and Mechvibes
packs can be imported.

## 3. Playback timing

**Observed** (preview engine):

- Web Audio `AudioBufferSourceNode` → `GainNode` → destination. Buffers are decoded once
  and cached in a `Map`.
- Each key: `down` plays at `t`, `up` plays at `t + 125 ms`, and the next key starts
  `250 ms` later. Pauses are `500 ms`.

**Design:** the native app plays `down` when the key-down event arrives and `up` when the
key-up event arrives, so timing follows your fingers. The in-app "Preview" button reuses
the exact 250 / 125 / 500 ms timings above.

## 4. Switch sets

**Observed** (`../assets/switches/*.json` inlined in the bundle):

| slug | brand | name | colors |
|------|-------|------|--------|
| cardboard | Flurples | Cardboard | `#f7baa1 → #f28c61` |
| cream | NovelKeys | Cream | `#fff3e6 → #fecf9a` |
| crystal-purple | Everglide | Crystal Purple | `#f1acfb → #e879f9` |
| japanese-black | CherryMX | Japanese Black | `#878078 → #44403c` |
| milky-yellow | Gateron | Milky Yellow | `#fef6d7 → #fde481` |
| oreo | Everglide | Oreo | `#b2ada9 → #78716c` |
| super-red | — | Super Red | — (added later; changelog calls it "a very thocky switch set") |

Each set is a real switch recorded by the developer. **Design:** OpenThock can't ship
those recordings, so it includes a **Keyboard Recorder** that builds a set from *your*
keyboard the same way (one press and one release per key), plus three procedurally
generated starter sets.

## 5. Feature list (from the public changelog)

| Klack feature (Observed, changelog) | OpenThock |
|---|---|
| Per-key down/up sounds, numpad and function-key support | ✅ Same file naming |
| "Added randomized rate support to audio engine" | ✅ Tiny per-press playback-rate jitter (`Variation`) |
| "Tone Pad — tune any switch set… unique variation each time" | ✅ 2-D Tone Pad: X = pitch, Y = variation |
| "Spatial Audio — 3D with AirPods, 2D otherwise" | ✅ Stereo pan by key position; 3-D (ITD/ILD + head-shadow) on headphones; Auto mode |
| "Improved spacebar-key sound by toning it down" | ✅ Per-group gain in `pack.json` |
| Mouse click sounds, scroll sounds | ✅ |
| "Ding sound on return key press" option | ✅ |
| "Setting to disable audible modifier keys" | ✅ |
| "Changed to ignore synthetic inputs" | ✅ Only HID-originated events play |
| Selected / system output device | ✅ |
| Hotkey to toggle | ✅ ⌃⌥K |
| Sleep triggers (focus, media, calendar, screen share, gaming) | ⚠️ Partial: per-app mute + timed sleep |
| Stats | ✅ Today / total / top key |
| "Decreased latency" | ✅ Custom C real-time mixer, 256-frame IO buffer |
| AppleScript / Raycast | ❌ Not yet |

## 6. Engine architecture (Design)

```
CGEventTap (listen-only, HID events only)
   │  keyDown / keyUp / flagsChanged / NX_SYSDEFINED media keys / mouse / scroll
   ▼
KeyMap  macOS kVK → uiohook code ("37"), group, physical position
   ▼
SoundBank  code → (downSample, upSample) with deterministic same-group fallback
   ▼
SoundPlayer  rate = pitch·(1 ± variation), gains + spatialization
   ▼  lock-free SPSC queue
CMixer (C, real-time thread)  96 voices, linear-interp resampling, ITD/ILD/head-shadow
   ▼
AVAudioSourceNode → AVAudioEngine → selected output device
```

A missing key is never randomized. It is filled from a sibling in the same group (for
example, other alpha keys), chosen by a stable hash of the key code. This keeps the
"same key → same sound" property even for partial packs.
