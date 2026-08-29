# Design System

The brief asked for the UI to match the supplied screenshots. This document records how that
was done, and how the two apps stay visually coherent while sharing no code.

---

## 1. The palettes were transcribed, not eyeballed

The reference screenshots are embedded images inside the brief's PDF. They were extracted,
rendered at 12× zoom, and their dominant colours **sampled programmatically** before any UI
code was written.

That is why the palettes carry values like `#2B6EEA` rather than the nearest familiar swatch.
The originals are in [`design/`](../design/).

### Anchorage Perimeter — light, minted

| Role | Value | Where it came from |
| --- | --- | --- |
| Background (top → bottom) | `#F5FAFA` → `#F0F5F5` | The two most common pixels in the screenshot |
| Surface | `#FFFFFF` | Cards, app bar |
| Primary | `#2B6EEA` | Title, outlined button, status dot |
| Danger arc | `#F06363` | The ring's red sweep |
| Danger text | `#EB4141` | `OUT OF RANGE` label |
| Danger container | `#FAF0F0` | The pill's background |
| Dial fill | `#FAF5F5` | Inside the ring |
| Disabled container | `#C8D2E1` | The disabled Mark Attendance button |
| Dashed outline | `#C9D2D8` | The check-in panel border |
| Text primary | `#2F3542` | `120m` |
| Text secondary | `#6B7580` | Body copy |
| Text tertiary | `#A0A8B3` | Helper caption |
| Map park / alt | `#C3D7C8` / `#BED7C3` | The map thumbnail's greens |

Green and amber roles were added for states the reference does not show (in range, weak
signal, checked in), chosen to sit in the same tonal family.

### Anchorage Harbor — near-black navy

| Role | Value |
| --- | --- |
| Background | `#000514` |
| Background elevated | `#050A19` |
| Panel (header bands) | `#0A1428` |
| Card | `#0F1428` |
| Card active | `#101A30` |
| Hairline | `#0F2332` |
| Primary | `#235FEB` |
| Primary bright (progress, accents) | `#3782F5` |
| Success | `#1EA97C` |
| Caution | `#E0A33B` |
| Danger | `#F26F6F` |
| Text primary / secondary / tertiary | `#F2F4F8` / `#919196` / `#5A6469` |
| Camera scrim | `#66000000` |

Harbor is **dark-only by design, not by omission**: it is a camera app, and light chrome
around a live preview both wrecks night vision and shifts the apparent colour of everything
the user is framing.

---

## 2. Semantic roles, never raw pigment

Neither app allows a colour literal at a call site.

```kotlin
// Android
color = AnchorageTheme.colors.dangerArc          // ✅
color = Color(0xFFF06363)                        // ❌
```

```dart
// Flutter
color: context.harborColors.caution              // ✅
color: const Color(0xFFE0A33B)                   // ❌
```

Raw swatches are `internal` / private to the palette file; screens see only roles like
`dangerArc`, `disabledContainer`, `cameraScrim`, `primaryBright`. A re-skin — or a future dark
theme for Perimeter — is a single-file change, and the *reason* a pixel is red survives into
the code.

---

## 3. Type scales named by role

Both apps use a short scale named for the job rather than a generic rung (`titleMedium`).
Naming by role stops a developer reaching for a near-miss and slowly eroding the design.

### Perimeter — `AnchorageTypography`

| Style | Size / weight | Used for |
| --- | --- | --- |
| `screenTitle` | 20sp Bold | "Attendance" |
| `sectionEyebrow` | 11sp SemiBold, +1.3 tracking | "STEP 1: OFFICE CONTEXT" |
| `body` | 13sp Regular, 19sp line | Card copy |
| `caption` | 12sp, centred | Helper sentence under the dial |
| `dialValue` | 34sp Bold, −0.5 tracking | "120m" |
| `microLabel` | 10sp Bold, +1.6 tracking | "AWAY", "OUT OF RANGE", "AVAILABLE …" |
| `button` | 15sp SemiBold | Button labels |
| `coordinate` | 11sp **Monospace** | "Lat: 23.7808, Lon: 90.4143" |

### Harbor — `HarborTypography`

| Style | Size / weight | Used for |
| --- | --- | --- |
| `screenTitle` | 22 Bold | "Upload Manager" |
| `eyebrow` | 10 SemiBold, +1.6 | "BATCH SYNC PROGRESS", "PENDING UPLOADS (5)" |
| `itemTitle` | 14 SemiBold | File names |
| `itemMeta` | 11 Regular | Sizes |
| `itemStatus` | 10 Bold, +1.1 | "RETRYING... (ATTEMPT 3/5)" |
| `button` | 13 Bold, +1.2 | "UPLOAD BATCH (12)" |
| `numeric` | 11 SemiBold, **tabular figures** | "74%", "12 MB/s" |

Two deliberate choices:

* **Wide tracking on the eyebrow styles is not decoration.** The reference relies on it to
  make 10–11sp uppercase labels legible.
* **Monospace and tabular figures** stop digits from jittering as they update — a coordinate
  or a throughput read-out that reflows every 500 ms reads as instability.

---

## 4. Spacing and shape

Both apps use a 4dp ladder. Hard-coded `16.dp` literals scattered through a screen are how
layouts drift out of rhythm.

```
xxs 4 · xs 8 · sm 12 · md 16 · lg 20 · xl 24 · xxl 32
```

Radii are named for the component that owns them:

| Token | Perimeter | Harbor |
| --- | --- | --- |
| card | 20dp | 14 |
| thumbnail | 14dp | 12 |
| button | 12dp (outlined) / 14dp (filled) | 14 |
| pill | 50 % | 999 |
| dashed panel | 20dp | — |

---

## 5. The components

### Perimeter (`core/designsystem/`)

| Component | Notes |
| --- | --- |
| `AnchorageCard` | 1dp elevation — Material's default black shadow reads as a grey smudge on the minted background |
| `SectionEyebrow` | Uppercase label with an optional status dot |
| `StatusPill` | Rounded chip; **always carries a text label**, never colour alone |
| `DashedPanel` | Compose has no dashed border modifier; drawn with `drawBehind` + `PathEffect.dashPathEffect`, *behind* the content so dashes stay crisp at the radius |
| `AnchoragePrimaryButton` / `AnchorageOutlinedButton` | Full-width, token-driven |
| `DistanceDial` | The centrepiece — see below |
| `MiniMapPreview` | Procedural map, seeded by coordinates |
| `CoordinateChip` | The floating white lat/lon pill |
| `AnchorageBanner` | Persistent problem banner with a mandatory action |

### Harbor

| Component | Notes |
| --- | --- |
| `GlassCircleButton` | Translucent chrome — solid buttons hide the frame being composed |
| `VerticalZoomSlider` | Hand-built; a rotated Material `Slider` inverts its own gesture axis and cannot put labels inside the track |
| `ZoomStopSelector` | Selected pill inverts to solid white, exactly as in the reference; it shows the *live* zoom (`1.7x`) whenever the value sits between stops, and collapses only when the sensor offers a single stop |
| `CompositionGrid` | Optional rule-of-thirds guide at 22 % white — guides that shout make people frame to the lines instead of the subject |
| `ShutterButton` | Disc inside a ring; shrinks while capturing — the cheapest possible tap confirmation that does not obscure the frame |
| `BatchThumbnail` | Newest shot with a blue count badge; opens the batch review sheet; `errorBuilder` for a deleted file |
| `BatchReviewSheet` | The shots not yet handed over, as a bounded scrolling grid; tap to drop one |
| `CameraSettingsSheet` | Flash as an explicit four-way choice, the composition grid, and the mock-transport switch |
| `FocusReticle` | Yellow square, `easeOutBack`, mirroring the platform camera apps users know |
| `LinkBadge` | Three states, not two |
| `BatchProgressHeader` | Byte-weighted bar with the pause control |
| `UploadTaskTile` | Active row lifted with a blue hairline and inline progress; file-name stem in white with the extension muted; delivered rows dimmed to 55 % |
| `EmptyQueueView` | The state a well-behaved sync engine spends most of its life in, so it gets more than a blank rectangle |

---

## 6. Two components worth explaining

### `DistanceDial`

* The arc starts at 12 o'clock (`-90°`) and sweeps clockwise, so "more arc" reads
  unambiguously as "further away".
* Progress and colour are **both animated** (450 ms / 300 ms). Raw GPS jitters by several
  metres a second; without the tween the ring visibly twitches and the screen feels broken
  even when the data is fine.
* A minimum sweep of 2° means standing exactly on the anchor still renders a visible tick
  rather than a bare track.
* The whole dial is **one semantic node** — "You are 120 metres away from the office" — because
  a screen reader announcing "120" and "AWAY" as unrelated nodes is useless.

### `MiniMapPreview`

The reference card shows a map. A real `MapView` means a billed API key, a network round-trip,
a heavyweight dependency and a second permission surface — for decoration inside a card.

So the tile is **generated** from the anchor's own coordinates: two park blocks, a river, a
minor grid and two arterial roads, all drawn in normalised units from a seeded `Random`. The
same office always renders the same street pattern; two different offices look visibly
different. The "this is your saved place" signal survives with zero dependencies.

---

## 7. Accessibility

Rules that are already met and must stay met:

* **State is never carried by colour alone.** Every status has a text label — `OUT OF RANGE`,
  `WEAK SIGNAL`, `WAITING FOR CONNECTION`, `SYNCED` — so it survives greyscale printing and
  colour-blindness.
* **The dial is one semantic node** with a full-sentence description.
* **The check-in button announces its gate**: "Mark attendance, available" / "…, locked".
* **Camera chrome carries labels**: "Close camera", "Flash mode", "Capture photograph",
  "0.5 times zoom", "12 photographs in this batch".
* **Tap targets** are at least 40dp; the shutter is 74dp.
* **Numeric read-outs use tabular figures**, so digits do not reflow as they update.
* **Text scales with the system font size** — no `sp`-to-`dp` shortcuts anywhere.

---

## 8. Fidelity to the reference, and where it was extended

The reference screenshots show exactly **one state** of each screen. Everything below that
state was designed to match, not to invent:

| Screen | In the reference | Added, in the same language |
| --- | --- | --- |
| Attendance | Out of range, office set, window open | In range (green), weak signal (amber), no office, checked in, window closed, six banner types, loading |
| Camera | Idle preview with 12 queued | Capturing, submitting, permission required, permission blocked, no camera, preview paused |
| Upload Manager | Mixed queue, stable link | Empty queue, paused, weak/no link, per-row retry and discard, clear-synced, mock switcher |

Every added state reuses existing tokens and components. No new colour was invented that is
not a tonal sibling of one sampled from the reference.
