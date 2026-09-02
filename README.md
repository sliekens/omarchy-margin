# Margin — screen-edge ring

An [Omarchy](https://omarchy.org/) shell plugin that turns the window gap
around the screen edge into a music visualiser.

Omarchy's `gaps_out` band — the strip of desktop between the bar and the
outermost tiles — is space you have already paid for and nothing draws in.
Margin fills it with a ring that spans the gap while sound is playing,
coloured from the album art of the current track, with its gradient sweeping
around on every detected beat. Mute, and it retracts back to the screen edge
and disappears.

It is the first cell of a larger idea: **turn Omarchy's window gaps into UI**.
The screen edge is the easiest surface to prove it on, because it needs no
per-window geometry tracking.

## Install

```bash
omarchy plugin add https://github.com/sliekens/omarchy-margin.git
omarchy plugin enable sliekens.margin
```

Plugins land disabled so you can read the code before it runs — it executes
unsandboxed inside your long-lived `omarchy-shell` process. Update with
`omarchy plugin update sliekens.margin`, remove with `omarchy plugin remove
sliekens.margin`.

Requires nothing beyond a stock Omarchy box: `pw-cat` (pipewire), `magick`
(imagemagick), `hyprctl`, and the Python 3 standard library.

## How it works

```
bin/margin-audio   pw-cat taps the default sink's monitor -> FFT -> 28 log
                   bands + spectral-flux beat detection + noise gate -> one
                   JSON line per frame (~43/sec) on stdout
bin/margin-palette MPRIS trackArtUrl -> ImageMagick quantize -> 4 ring colors
Margin.qml         layer-shell surface per screen, inset by the bar's reserved
                   area so it lands exactly in the gap; one continuous Shape
                   whose inner contour is modulated by the spectrum
```

The ring is a **single filled shape**, not segments: two closed contours
filled odd-even, so there are no internal edges or seams anywhere, corners
included. It is anchored at the **screen edge** and its span across the gap is
driven by overall loudness: silence leaves a hairline against the screen edge,
and anything at or above `loudFull` fills the gap completely, touching the
window with no gap anywhere.

The spectrum lives in the **color**, not the shape. Letting it carve the inner
edge is what left a notch at every trough — the ring is a solid band, and band
energy drives the intensity of the gradient stop sitting at that point, so the
spectrum reads as light travelling around the ring. The spectrum is
**mirrored** around it: bass at the bottom centre, rising through the sides,
treble meeting at the top centre.

Color comes from a conical gradient rather than per-segment fills, so it
varies continuously; each beat rotates the gradient, which reads as the colors
sweeping around the edge. Beats deliberately do **not** touch the geometry —
see the note on cost below.

The surface has an empty input region (`mask: Region {}`) and
`ExclusionMode.Ignore`, so it is visual only — it never eats a click and never
reserves space.

## Dependencies

None beyond a stock Omarchy box: `pw-cat` (pipewire), `magick`
(imagemagick), `hyprctl`, python3 stdlib. No cava, no numpy.

## Config

### Transitions

The ring's span across the gap is a single animated property (`fillAmount`,
0 = collapsed on the screen edge, 1 = touching the window). Muting animates it
to 0 over `retractMs` (ease-in-out quint); unmuting expands it back over
`expandMs` (ease-out cubic).

There are **two ways sound can stop**, and they need different handling:

- *Sink muted* (keyboard mute key, `pactl set-sink-mute`) — caught by the mute
  property, `showRing` flips, and the quint animation runs.
- *The stream stops* (app mutes itself, playback pauses, track gap) — the sink
  is never muted, so the only signal is the level collapsing to zero, which it
  does within a single frame.

The second path used to snap the ring shut instantly and leave a hairline
sitting there until the silence timer fired ~1.5s later. Two causes: the
per-tick span assignment had no smoothing, so a one-frame level collapse moved
the ring the whole way in one 33ms tick; and `liveFill()` returned `floorRatio`
rather than 0 at silence, which is what the leftover hairline was. The span now
uses a fast attack / paced release (release timed to land in about
`retractMs`), and the floor applies only when there is actually sound.

Measured on screen, ring rows lit out of a 20px gap:

```
app / stream mute   20 17  9  5  3  2  1  1  0     (smoothed release)
sink mute           20 20 20 18 12  3  1  0        (quint animation)
```

**The ring stays fully lit while it retracts.** It disappears because its span
reaches zero, not because it faded. Fading in parallel — the obvious thing to
do — is why the easing was invisible: opacity was near zero by the time the
ease-out tail played, so a 10px travel just read as "it vanished".

Measured span trace on mute, which is the S-curve doing its work:
`100, 100, 99, 98, 95, 89, 77, 60, 35, 20, 9, 4, 2, 0`.

Note that sampling this through `margin status` understates the duration: each
IPC call costs ~60ms and the reported percent rounds to 0 while the quint tail
is still running. Timed from inside QML, a `dur=2000` retract takes 1914ms.

While a transition is running it owns `fillAmount` and the per-frame level
updates leave it alone, resuming once the animation finishes. This is the one
place the contour is rebuilt at 60fps rather than 30 — acceptable because it
only happens on a transition, never in steady state.

Every key has a built-in default, so `config.json` is optional. Copy
`config.example.json` to `config.json` to override anything; it hot-reloads on
save (it is read at runtime, not compiled in) and is deliberately untracked,
because `omarchy plugin update` is a `git merge --ff-only` that a modified
tracked file would block.

| key | default | meaning |
|-----|---------|---------|
| `enabled` | `true` | master switch; stops the producer when false |
| `samples` | `160` | contour sample points; higher = smoother, costlier |
| `thickness` | `0` | ring thickness; `0` = auto-detect `general:gaps_out` |
| `floorRatio` | `0.12` | span at silence, as a fraction of the gap |
| `loudFull` | `60` | level (0-100) at which the ring fills the gap completely |
| `depth` | `0` | >0 re-carves the inner edge by the spectrum (leaves gaps at troughs) |
| `gamma` | `1.0` | contour response curve; <1 lifts quiet bands, 1 = linear |
| `angleOffset` | `90` | gradient start angle; 90 puts position 0 at the bottom |
| `anchorToWindow` | `false` | `true` flips the anchor to the window side instead |
| `idleOpacity` | `0` | `0` = nothing drawn when silent or muted; raise for a faint idle ring |
| `silenceHold` | `1500` | ms of silence before the ring retracts |
| `retractMs` | `800` | retraction duration on mute/silence |
| `expandMs` | `420` | expansion duration when sound returns |
| `beatShiftsPalette` | `true` | rotate colors one stop per beat |
| `fallbackColors` | 4 colors | used when there is no album art |

## IPC

```bash
omarchy-shell margin status     # level, bpm, palette, track, thickness
omarchy-shell margin repalette  # re-extract colors from the current art
```

## Verified

- Beat detection regression: synthetic 120 BPM click track → 23/24 beats,
  0.501s mean interval. Live: 129 BPM on a 127 BPM track.
- Capture is bound to the sink monitor (source 56), not the mic (58).
- Silence in → zeros out: all bands 0, no beats, ring fades out.
- Muted → nothing drawn at all: two frames 1.5s apart are pixel-identical
  across the gap, the producer and its pw-cat both exit, shell CPU reads 0%.
- The mute/unmute transition animates rather than cutting: captured at full,
  mid-retraction and gone, the ring is a bright band, a bright narrower band,
  then nothing. Steady-state CPU is unchanged by it.
- Fill reaches 100% of the gap at normal playback levels (`margin status`
  reports the live min/max as `fillPercent`).
- Cost: producer ~2% of one core; ring ~3-4% (measured over 8s windows
  against the shell with `enabled: false` as baseline, which reads 0%).
- Kill the producer → watchdog restarts it within 1s.
- `pw-cat` child is reaped on exit, so reloads don't orphan capture processes.

## Three things worth knowing

**Muting a sink does not silence its monitor.** PipeWire taps the mix *before*
the sink's own mute and volume, so a muted desktop still produces a full
spectrum — measured: level held at ~68 and beats kept firing throughout a
mute. Silence detection can never cover this. The plugin reads
`Pipewire.defaultAudioSink.audio.muted` (and treats volume 0 the same) and,
while muted, hides the ring *and* stops the capture process entirely.

**Never let pw-cat pick its own source.** PipeWire has no separate node for a
monitor: you capture a sink's monitor by targeting the *sink itself*. The
`<sink>.monitor` name is a PulseAudio-ism, and passing it to `pw-cat --target`
matches nothing — pw-cat then silently falls back to the default source, which
is the **microphone**. `sink_node_id()` resolves a real node id and the code
exits rather than capturing an unresolved source.

**Keep animation out of the geometry.** Letting the beat pulse modulate the
contour meant re-triangulating a 160-point path at 60fps for 400ms after every
beat: that alone took the ring from 3% to 16% of a core. The beat now drives
opacity, which costs nothing, and the contour rebuilds on a 30fps tick fed by
the producer's 43fps frames.

## Known limits

- **Hot-reload serves stale QML.** Editing `Margin.qml` triggers a reload that
  re-instantiates *previously compiled* code; `omarchy-shell shell
  rescanPlugins` does not help. `omarchy restart shell` is required. Editing
  `config.json` or the python producers is unaffected.
- Layer is `Top`, so the ring draws over fullscreen windows.
- BPM is quantised to the 23ms frame, so it lands within ~3 BPM.
- Beat detection is bass-onset based: it does well on music with a kick and
  poorly on sparse or beatless material.

## License

MIT — see [LICENSE](LICENSE).
