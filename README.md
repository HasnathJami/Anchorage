# ⚓ Anchorage

**A two-app field-operations suite: know where you are, never lose what you captured.**

Anchorage is the submission for the Senior App Developer Technical Assessment. It is one
project containing two applications that share a name, a design language and an
architectural doctrine — and nothing else, because the brief asks for two genuinely
independent stacks.

| App | Stack | What it does |
| --- | --- | --- |
| **Anchorage Perimeter** | Native Android · Kotlin · Jetpack Compose · Kotlin Flow · Hilt | Anchors an office coordinate and lets a user mark attendance only from inside a 50 m geofence, with a live distance dial. |
| **Anchorage Harbor** | Flutter · Dart · BLoC · get_it | Custom camera with pinch/slider/lens zoom and tap-to-focus, batch capture, and a durable upload queue that survives no signal, low bandwidth, process death and reboot. |

### Why "Anchorage"?

An anchorage is a place a vessel can hold position safely. Both halves of this assessment
are the same idea in different clothing:

* **Perimeter** anchors you to a *place* — a fixed coordinate everything is measured against.
* **Harbor** anchors your *cargo* — captured evidence is held fast in a local queue and only
  released when it has genuinely reached shore.

The anchor even appears in the reference design: it is the icon on the "UPLOAD BATCH" button.

---

## Table of contents

1. [Repository layout](#repository-layout)
2. [Task 1 — Anchorage Perimeter (Native Android)](#task-1--anchorage-perimeter-native-android)
3. [Task 2 — Anchorage Harbor (Flutter)](#task-2--anchorage-harbor-flutter)
4. [Project structure and architectural approach](#project-structure-and-architectural-approach)
5. [Generative AI usage](#generative-ai-usage)
6. [How to run](#how-to-run)
7. [Testing](#testing)
8. [Screenshots](#screenshots)
9. [Further documentation](#further-documentation)

---

## Repository layout

```
Anchorage/
├── android/                     # Task 1 — Anchorage Perimeter (one Gradle module)
│   └── app/src/main/kotlin/com/anchorage/perimeter/
│       ├── presentation/        #   MVI ViewModels + Compose screens, navigation
│       ├── domain/              #   entities, policies, ports, use cases  (no Android types)
│       ├── data/                #   FusedLocation, DataStore, Room adapters
│       ├── di/                  #   Hilt modules: ports → adapters, use-case assembly
│       └── core/
│           ├── common/          #   Outcome<T>, AppError taxonomy, dispatchers
│           └── designsystem/    #   colour/type/shape tokens + shared composables
│
├── flutter/                     # Task 2 — Anchorage Harbor (same layers, Dart idiom)
│   └── lib/
│       ├── app/                 #   shell, routes
│       ├── di/                  #   get_it composition root
│       ├── background/          #   WorkManager isolate entry point
│       ├── presentation/        #   capture/ and sync/: Blocs, pages, widgets
│       ├── domain/              #   entities, policies, ports, use cases  (no plugins)
│       ├── data/                #   camera, SQLite queue, connectivity, schedulers
│       └── core/                #   Failure taxonomy, Result<T>, design tokens
│
├── docs/                        # feature-by-feature and cross-cutting documentation
├── design/                      # reference screenshots from the brief
├── CLAUDE.md                    # working agreement for AI assistants on this repo
├── PROMPTS.md                   # every prompt used to build this project
├── IMPROVEMENTS.md              # what was added beyond the brief, and why
└── README.md                    # you are here
```

---

## Task 1 — Anchorage Perimeter (Native Android)

A single `AttendanceScreen` that handles both setup and check-in, exactly as the brief
requires.

### What the brief asked for, and where it lives

| Requirement | Implementation |
| --- | --- |
| Button to "Set Office Location" that fetches GPS and saves locally | `OfficePickerRoute` — a map with a draggable perimeter, seeded by `CaptureOfficeAnchorUseCase`’s fix and confirmed by `PlaceOfficeAnchorUseCase` → `OfficeAnchorLocalSource` (DataStore) |
| "Mark Attendance" enabled only within 50 m | `GeofenceEvaluator` + `AttendanceStatus.canMarkAttendance`; re-validated authoritatively in `MarkAttendanceUseCase` |
| Real-time distance indicator | `DistanceDial` fed by `ObserveAttendanceStatusUseCase` |
| Jetpack Compose UI matching the screenshot | `AttendanceScreen.kt` + `core/designsystem/` |
| Kotlin Flow state management | Every read path is a `Flow`; the ViewModel exposes `StateFlow<AttendanceUiState>` |
| Graceful permission and hardware failure handling | `AppError.Location` taxonomy → `AttendanceNotice` → inline banner with a remedy |

### The screen, state by state

* **No office anchored** — the dial reads `--`, the pill reads `OFFICE NOT SET`, the
  check-in panel is locked, and the card's status dot is grey.
* **Out of range** — red arc proportional to `distance / 50 m`, `120m` in the centre,
  `OUT OF RANGE` pill, and the instruction *"Move within 50 meters of the designated office
  location to enable check-in."*
* **In range** — the arc, pill and padlock all turn green/blue together and the button
  becomes pressable.
* **Weak signal** — a fix whose own error radius is wider than the fence is reported as
  `WEAK SIGNAL` in amber, not as a false "in range". See
  [Improvement #2](IMPROVEMENTS.md).
* **Already marked today** — green `CHECKED IN` pill with the time and distance of the
  recorded check-in.
* **Window closed** — the caption under the button flips from `AVAILABLE 09:00 AM - 10:30 AM`
  to `WINDOW CLOSED`, in amber.

### Stack

Kotlin 2.2.21 · AGP 8.13.2 · Gradle 8.14.3 · Compose BOM 2025.12.01 · Hilt 2.57.2 ·
Room 2.8.4 · DataStore 1.1.7 · Play Services Location 21.4.0 · minSdk 26 · targetSdk 36

---

## Task 2 — Anchorage Harbor (Flutter)

Two screens: `CameraPreviewScreen` and the Upload Manager.

### What the brief asked for, and where it lives

| Requirement | Implementation |
| --- | --- |
| Custom camera preview screen | `CameraPreviewPage` — full-bleed preview with floating chrome |
| Pinch-to-zoom | `CameraPinchStarted` / `CameraPinchZoomed`, anchored to the zoom the gesture began at |
| Zoom slider | `VerticalZoomSlider` — hand-built, because a rotated Material `Slider` inverts its own drag axis |
| Rounded zoom buttons (0.5x, 1x, 2x) | `ZoomStopSelector` over the `ZoomLadder` policy — see [Why the zoom buttons are ratios, not cameras](#why-the-zoom-buttons-are-ratios-not-cameras) |
| Tap-to-focus with a visual indicator | `CameraFocusRequested` → `FocusReticle` — a ring, an AE/AF padlock and a brightness slider, shown optimistically and cleared on a dwell timer |
| Batch capture with a "Pending Uploads" list | `CaptureBatch` → `BatchReviewSheet` → `EnqueueBatch` → `UploadManagerPage` |
| Background worker monitoring connectivity | `WorkManagerScheduler` + `syncCallbackDispatcher` |
| Images stay queued on failure | SQLite-backed `UploadQueueRepositoryImpl`; nothing leaves the queue until the server acknowledges it |
| Automatic retry on a stable connection, no user action | `ConnectivityMonitor` (with a settle window) → `UploadManagerBloc` → `ProcessUploadQueue` |
| No API available — mock success and failure | `MockUploadApi` (working transport) + `http_upload_api.dart` (real transport, fully written and commented out) |

### The camera screen, control by control

Read top to bottom, exactly as the reference design is laid out.

| Control | Behaviour |
| --- | --- |
| **✕**, top left | Asks before closing the app — see [Closing the app](#closing-the-app). It used to call `maybePop`, which on the root route pops nothing: the button did nothing at all. |
| **Flash**, top right | Cycles off → auto → on → torch. The *glyph* changes with the mode, so the state is never carried by colour alone. The torch has an idle deadline so a pocketed phone does not cook its own LED. |
| **⚙**, top right | Opens `CameraSettingsSheet`: a rule-of-thirds grid, the mock-transport switch, and a route to the Upload Manager. Flash is deliberately absent — it lives on the top bar, and one setting with two controls is one control too many. |
| **Viewfinder** | Tap to focus *and* meter exposure — tapping a dark corner and getting a sharp but unreadable frame is not what the gesture means. Pinch to zoom, anchored to where the gesture started. See [The focus reticle](#the-focus-reticle-lock-and-brightness). |
| **Vertical slider**, right edge | Absolute zoom across the offered band, labelled at both ends. Drag up zooms in. |
| **0.5 / 1 / 2**, above the shutter | Quick zoom. The selected pill reads the *live* value (`1.7x`) whenever the zoom sits between stops. |
| **Thumbnail + badge**, bottom left | Opens `BatchReviewSheet` — the shots that have **not** been handed over yet, where a blurred frame can still be dropped for free. With an empty batch it goes to the Upload Manager instead. |
| **Shutter** | One photograph per completed capture; the event is `droppable`, so hammering the button cannot queue twelve. |
| **Flip**, bottom right | Front ⇄ rear. |
| **UPLOAD BATCH (n)** | Hands the batch to the sync engine and starts a fresh one. With nothing captured it reads `UPLOAD MANAGER` and goes there, rather than sitting grey through the whole of a first run. |

The thumbnail, shutter and lens-flip button share one centre line, and the shutter is centred
on the screen rather than merely spaced evenly between two neighbours of different widths.

#### The focus reticle: lock and brightness

Tapping the viewfinder does not just focus. It places a reticle modelled on the platform
camera apps — the familiarity *is* the feature, because nobody reads a manual for a
viewfinder:

* **A ring** marks where the sensor is metering. Non-interactive, so a tap inside it
  re-meters there rather than being swallowed.
* **A padlock** on the ring at twelve o'clock holds focus *and* exposure. Open by default,
  closed while locked. The two are locked together on purpose: every camera app presents this
  as one control, because the situation it exists for is one situation — *I have framed this,
  stop changing it.*
* **A brightness slider** beneath — a sun on a track — sets exposure compensation for this
  metering point.

Three rules make it behave the way people expect:

1. **A locked reticle does not fade.** The dwell timer is cancelled while the padlock is
   closed. A lock the user cannot see is a lock they forget they set, and every photograph
   afterwards is metered for a subject they walked away from.
2. **A tap elsewhere is a new metering decision.** It releases the lock and returns the
   brightness to neutral, because both belonged to the old point.
3. **Nothing survives invisibly.** When the reticle fades, the exposure goes back to 0 EV —
   and releasing the sensor drops the lock with it, because a new controller starts at auto.

Exposure compensation is reported by Android in *steps* (commonly ±2 EV in thirds), and a
value off that grid is rejected or silently rounded. `ExposureRange` snaps every value before
anything else sees it, so the sun and the sensor can never disagree about where it is.

#### Closing the app

The camera is the app's root route, so the ✕ and the system back gesture both mean "close
Anchorage Harbor", not "pop a screen". Both go through one confirmation, and it is not a
generic *are you sure*: it says what closing actually costs.

Photographs live in the working batch from the moment the shutter fires until **UPLOAD
BATCH** hands them to the queue, and only the queue is durable. So when the batch is empty
the dialog says the queue keeps syncing in the background and offers **CLOSE** / **CANCEL**.
When it is not, it names the count and adds **UPLOAD & CLOSE**, which enqueues first and
closes second — and does not close at all if the enqueue fails, because closing then would do
exactly the thing the user chose to avoid. Backing out of the dialog counts as *stay*.

The app closes with `SystemNavigator.pop()`, not `exit(0)`: it asks the platform to finish
the activity so Flutter and the plugins shut down in order. Killing the process outright is
how a half-written SQLite transaction becomes a corrupted queue.

#### The zoom band: 0.5x – 8x

The controls are designed around 0.5x – 8x, and `ZoomRange` intersects that with what the
open sensor will admit:

* **The 8x ceiling is a product decision.** Plenty of phones report 10x or 30x; past roughly
  8x they are upscaling, not zooming. Those extra numbers also cost something real — mapping
  1x–30x onto the reference design's ~230 dp slider makes the 1x–3x band people actually use
  about twenty pixels tall.
* **The 0.5x floor is the hardware's to grant.** You cannot see wider than the lens, so a
  sensor that starts at 1x is offered from 1x. Most modern Androids publish a rear camera
  whose range already reaches 0.5; where instead the ultra-wide is a *separate* camera, the
  quick-zoom row still offers 0.5 and tapping it switches to that camera — the row is built
  from what the **device** can reach, not just the sensor that happens to be open.

#### Why the zoom buttons are ratios, not cameras

The obvious implementation of "0.5x / 1x / 2x" is one button per rear camera. It is also
wrong on nearly every Android phone, and it was the first thing fixed in this pass.

`availableCameras()` reports *logical* cameras. A phone with an ultra-wide, a main and a
telephoto typically publishes **one** rear camera whose zoom range spans all three; the
platform switches the physical sensor underneath as the zoom crosses a threshold. Building
the row from that list therefore produced a single pill — and the code then hid the row
entirely, because one pill that does nothing is worse than none. On the device a reviewer
actually holds, the reference design's most recognisable control rendered as empty space.

`ZoomLadder` builds the row from the sensor's real zoom range instead:

* 1x is always offered — it is the frame the user is looking at.
* A wide button appears only when the minimum is genuinely below 1x, and it targets that
  exact minimum, so a 0.6x ultra-wide is honestly labelled `0.6` and lands where the
  hardware stops rather than being silently clamped.
* 2x, 3x, 5x, 10x are offered only up to what the sensor reaches. Three buttons, as in the
  reference.
* For the minority of devices that publish each rear sensor separately, tapping a ratio the
  open camera cannot reach opens the rear camera that can, then sets the zoom.

### The sync engine in six rules

`ProcessUploadQueue` is the heart of the app. Every rule below has a test that fails if the
rule is removed.

1. **Never start without a stable link.** Offline or unsettled? Every task is parked in
   `waitingForConnection` *without spending an attempt*, and a network-constrained wake-up
   is requested from the OS.
2. **One task at a time.** Parallel uploads on a weak link starve each other.
3. **Connectivity failures do not consume attempts.** Losing signal is a pause, not a
   failure. Only real transport or server errors increment the counter.
4. **Unretryable failures stop immediately.** A 400 or a missing file fails once and is
   shown to the user rather than looped.
5. **The queue is the source of truth throughout.** Every transition is written before the
   next task starts, so process death mid-sweep loses at most one in-flight transfer.
6. **A task is claimed before it is uploaded.** Two sweeps genuinely race — the Bloc sweeps
   in the foreground the moment the link steadies, and WorkManager sweeps from a separate
   isolate with its own object graph, so neither can see the other's in-flight guard. The
   claim is a single conditional `UPDATE`; exactly one sweep wins the row. The mirror-image
   hazard — a process killed *holding* a claim, leaving a row stuck in `uploading`, which is
   not an eligible state — is undone by a lease: anything claimed longer than ten minutes ago
   with no progress is returned to the queue at the top of the next sweep. Without both
   halves the queue either sends a file twice or strands it forever.

### What actually starts a sweep

The rules above say what a sweep *does*. Equally important is when one begins, because an
engine that is correct but only runs every fifteen minutes looks broken:

| Trigger | Where |
| --- | --- |
| App launch | `UploadManagerBloc` — drains a queue left behind by a previous run |
| **The link becomes stable** | `UploadManagerBloc` — the brief's requirement in one line: no button, no user action |
| **New work is queued** | `UploadManagerBloc` — tapping `UPLOAD BATCH` on an already-stable link used to upload nothing until WorkManager next woke; the rows just sat at `IN QUEUE` |
| **A backoff elapses** | `UploadManagerBloc` — a retry scheduled four seconds out had no foreground trigger at all, so the row read `RETRYING...` and then did nothing for fifteen minutes |
| OS wake-up, app closed | `WorkManagerScheduler` — a one-shot constrained to `NetworkType.connected`, plus a 15-minute periodic safety net |

Only the first two existed at first. The last two are what make the engine look as resilient
as it is, and each has a test that fails without it. The third and fourth needed a matching
fix underneath: `claim` and `requeueStalled` now republish the queue **only when they change
it**, because the reaper runs at the top of every sweep and an unconditional notification
would have put the engine in a permanent sweep-notify-sweep loop.

Retries use **exponential backoff with full jitter** (4 s → 8 s → 16 s …, capped at 15 min,
randomised across `[0, computed]`). Jitter matters: twelve photographs fail together when a
tunnel swallows the signal, and without it all twelve wake at the same millisecond.

### The mock API

The brief states no API is available. Anchorage Harbor answers that in both of the ways the
brief permits:

* **`MockUploadApi`** is a *working* transport, not a stub. It streams realistic progress at
  a configurable throughput, fails at a configurable point, and returns the full failure
  taxonomy. A switcher inside the camera's **⚙ settings sheet** offers two outcomes named
  for what the *user* would experience rather than for a status code — success, low
  bandwidth, no internet, and server error — and changes the behaviour live, so every path can be demonstrated on a real device in seconds. It sits
  there rather than on the Upload Manager because the reference design's bottom bar carries
  one button and nothing else.
* **`http_upload_api.dart`** is the production HTTP implementation, written out in full and
  commented out. Swapping them is one line in `injector.dart`.

### Stack

Flutter 3.38 · Dart 3.10 · flutter_bloc 9 · bloc_concurrency · get_it 9 · camera 0.12 ·
sqflite 2.4 · connectivity_plus 7 · workmanager 0.10 · permission_handler 12 · minSdk 24

---

## Project structure and architectural approach

Both apps follow the same layered (clean) architecture with dependencies pointing **inward
only**, and both use an MVI-flavoured presentation layer.

```
       ┌──────────────────────────────────────────┐
       │  Presentation   Compose / Widgets        │   knows: domain
       │                 ViewModel / BLoC         │
       ├──────────────────────────────────────────┤
       │  Domain         entities · policies      │   knows: nothing
       │                 ports    · use cases     │
       ├──────────────────────────────────────────┤
       │  Data           adapters implementing    │   knows: domain
       │                 the domain's ports       │
       └──────────────────────────────────────────┘
```

On Android the rule is **enforced by a test**. The app is a single Gradle module, so the layers
are packages rather than modules; `ArchitectureTest` reads the source tree and fails the build
on the first forbidden import, naming the file:

```
domain/ must not import android., androidx., com.google.android., dagger., javax.inject.
but was: [MarkAttendanceUseCase.kt: import android.util.Log]
```

"The domain knows nothing about the framework" therefore stays a checked invariant rather than
a code-review convention — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §2 for why the
earlier `kotlin-jvm` module boundary was traded for it.

### The main state holders

| App | Class | Responsibility |
| --- | --- | --- |
| Perimeter | `AttendanceViewModel` | Turns `AttendanceIntent` into use-case calls and projects `AttendanceStatus` onto `AttendanceUiState`; holds no geofence or window logic of its own. |
| Perimeter | `AttendanceHistoryViewModel` | Read-only projection of the attendance log. |
| Harbor | `CameraBloc` | Camera lifecycle, permissions, zoom/focus/lens, capture and batch hand-off. Shutter events are `droppable`, zoom events `restartable`. |
| Harbor | `UploadManagerBloc` | Watches the queue and the link; sweeps the queue the moment the link becomes stable. Hoisted above the navigator so sync continues while the user is on the camera screen. |

Both apps share two primitives worth naming:

* **`Outcome<T>` / `Result<T>`** — a two-case sealed result type. Failure is *data*, not
  control flow, so the compiler forces every caller to handle it.
* **`AppError` / `Failure`** — closed taxonomies where every case maps to a *different*
  remedy on screen. Adding a failure mode does not compile until someone has decided how to
  explain it to a user.

Full detail: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Generative AI usage

*This section is mandatory per the brief, and is answered honestly.*

This project was built in a single working session with **Claude (Opus 5) running inside
Claude Code**, driven by me. Every prompt I entered is recorded verbatim in
**[PROMPTS.md](PROMPTS.md)** — including the corrections, because the corrections are the
interesting part.

**How I used it.** I treated the model as a fast, tireless implementer and used my own
judgement as the architecture and review layer. Concretely:

1. **Requirements first, not code first.** I had the brief's PDF read and its embedded UI
   screenshots extracted and rendered at high zoom *before* any code was written, and the
   exact hex values of the reference design sampled programmatically from those images
   rather than eyeballed. That is why the palettes in `Color.kt` and `harbor_colors.dart`
   carry odd values like `#2B6EEA` and `#235FEB`.
2. **Architecture decided by me, typed by the model.** The layer boundaries, the decision to
   guard domain purity with a test rather than a Gradle module, the port/adapter split, the
   MVI contract shape and the five rules of the sync engine were specified up front; the model
   wrote them out.
3. **Test-first on every rule.** Each behavioural rule was expressed as a failing test before
   implementation, which is how bugs like *"the anchor-rejected banner is wiped by the next
   GPS update a fraction of a second later"* were caught — that one surfaced as a red test
   and produced the notice-ownership rule now documented in `AttendanceViewModel`.
4. **Verified, never assumed.** Nothing here is "it should compile". Every module was
   actually built and every test suite actually run, repeatedly, and the outputs are what the
   numbers in this README report.

**Representative prompts** (the full list is in PROMPTS.md):

> *"Read the PDF at E:/IM — extract the embedded UI screenshots and render them at high zoom
> so I can see the target design precisely, then sample the dominant colours so the palette
> is transcribed, not guessed."*

> *"Design the geofence as a pure domain policy with no Android types, so it can be tested on
> the JVM in milliseconds. Add hysteresis — a naive `distance < 50` check will strobe the UI
> when a user stands on the boundary and GPS jitters by a few metres."*

> *"The sync engine must treat 'no network' and 'server rejected it' as different things: the
> first parks the task without spending a retry attempt, the second spends one. Write the
> tests for both before the implementation."*

> *"Explain in the code comment *why* full jitter is used for backoff, not just that it is.
> A reviewer should learn something from the comment they could not have guessed."*

**What I did not do.** I did not accept generated code unread, and I did not ship anything
the build or the tests had not confirmed. Where the model's first attempt was wrong — the
notice-ownership bug above, a `Flow` type-widening error, a test that asserted on jittered
randomness instead of its ceiling — the fix is in the history and in PROMPTS.md.

---

## How to run

### Prerequisites

| Tool | Version used |
| --- | --- |
| JDK | **17 exactly** — Gradle 8.14.3 rejects 25+; both apps pin `jvmToolchain(17)` |
| Android SDK | Platform 36, Build-Tools 36 |
| Flutter | 3.38.9 (Dart 3.10.8) |

### Clone

```bash
git clone <your-repo-url> Anchorage
cd Anchorage
```

### Task 1 — Anchorage Perimeter (Android)

```bash
cd android

# Both apps build on JDK 17. Gradle 8.14.3 rejects JDK 25 (an Android Studio
# update can silently select it) — see "The JDK" in CLAUDE.md.
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"     # macOS/Linux/Git Bash
# setx JAVA_HOME "C:\Program Files\Android\Android Studio\jbr"     # Windows, once

./gradlew test              # all JVM unit tests
./gradlew assembleDebug     # debug APK  -> app/build/outputs/apk/debug/
./gradlew assembleRelease   # release APK -> app/build/outputs/apk/release/
```

Or open the `android/` folder in Android Studio and press Run.

`local.properties` is generated with an `sdk.dir` pointing at the machine that built it —
Android Studio will rewrite it, or edit it by hand.

**On device:** grant location permission when asked, tap **Set Office Location** while
outdoors (the app refuses a fix coarser than ±35 m — see
[Improvement #2](IMPROVEMENTS.md)), then walk out of and back into the 50 m radius to watch
the dial and the padlock respond.

> **Testing the geofence without walking 50 metres:** use the emulator's extended controls
> (⋯ → Location) or `adb emu geo fix <lon> <lat>` to move the device. The app flags mock
> providers in an amber banner but deliberately still accepts them — see
> [Improvement #6](IMPROVEMENTS.md).

### Task 2 — Anchorage Harbor (Flutter)

```bash
cd flutter

flutter pub get
flutter test                # all unit / bloc tests
flutter run --release       # on a connected device
flutter build apk --release # -> build/app/outputs/flutter-apk/app-release.apk
```

**On device, in order:**

1. Grant camera permission. Pinch, drag the slider, and tap `0.5` / `1` / `2` — the selected
   pill reads the live zoom between stops. Tap the frame to focus.
2. Take several photographs, then tap the **thumbnail** to review the batch and drop a frame
   you do not want. Discarding deletes the file, not just the list entry.
3. Tap **UPLOAD BATCH (n)**. The batch is written to SQLite before anything is sent.
4. Open **⚙ → MOCK API RESPONSE** and pick one of the two outcomes — `SUCCESS` or
   `FAILED` — then watch the Upload Manager. `FAILED` is a retryable 500, so one
   tap shows both halves of the policy: back off and retry a 5xx, stop dead on a 4xx.
5. For the real thing, turn off Wi-Fi and mobile data. The rows move to
   `WAITING FOR CONNECTION` and resume by themselves within a few seconds of the network
   returning — no button, no app restart. Kill the app entirely and WorkManager finishes the
   queue without it.

---

## Testing

Both apps are tested at the layer where the logic actually lives: fast JVM/Dart unit tests
over pure domain code, with fakes standing in for hardware.

| Suite | Tests | What it covers |
| --- | --- | --- |
| `android core/common/` | 6 | `Outcome` combinators |
| `android domain/` | 48 | Haversine arithmetic, geofence policy + hysteresis, attendance window, all five use cases |
| `android data/` | 17 | DataStore round-trip and corruption tolerance, Room date/timezone handling, location preflight |
| `android presentation/attendance/` | 25 | MVI reduction, permission escalation, every rejection path, formatters |
| `android architecture/` | 6 | The dependency rule itself — see [How the layers are enforced](#project-structure-and-architectural-approach) |
| `flutter` | 279 | Camera Bloc (52), sync engine incl. claim, lease, the bandwidth watchdog and the three-attempt budget (34), sync domain (17), zoom span across lenses (17), formatters (16), camera chrome widgets (17), upload manager Bloc incl. the five sweep triggers (16), zoom range (13), exposure range (13), zoom ladder (12), preview crop / tap-to-focus geometry (12), camera page: alignment + exit flow (10), mock transport (10), bandwidth policy (8), exit dialog (8), upload manager widgets (8), flash policy (7), top toast (6), architecture (4) |
| **Total** | **347** | |

Plus 5 Compose instrumentation tests (`./gradlew connectedDebugAndroidTest`) that
require a device or emulator.

```bash
cd android  && ./gradlew test        # 129 tests
cd ../flutter && flutter test        # 279 tests
```

Full philosophy and per-suite detail: **[docs/TESTING.md](docs/TESTING.md)**.

---

## Screenshots

Reference designs supplied with the brief are in [`design/`](design/). Screenshots of the
running applications belong in [`docs/screenshots/`](docs/screenshots/) — see the note in
that folder for the exact captures to take and the `adb` one-liner that grabs them.

---

## Further documentation

| Document | What is in it |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layering, module graph, dependency rules, DI strategy, and the decisions behind them |
| [docs/feature-geofenced-attendance.md](docs/feature-geofenced-attendance.md) | The geofence: maths, policy, hysteresis, the attendance window, the full state table |
| [docs/feature-camera-capture.md](docs/feature-camera-capture.md) | Camera lifecycle, zoom model, focus, lens discovery, batching |
| [docs/feature-resilient-sync.md](docs/feature-resilient-sync.md) | The sync engine end to end: queue schema, state machine, backoff, foreground/background split |
| [docs/ERROR-HANDLING.md](docs/ERROR-HANDLING.md) | Every failure mode in both apps and exactly what the user sees |
| [docs/DESIGN-SYSTEM.md](docs/DESIGN-SYSTEM.md) | Tokens, components, and how the reference design was transcribed |
| [docs/TESTING.md](docs/TESTING.md) | Strategy, fakes-over-mocks rationale, how to run everything |
| [IMPROVEMENTS.md](IMPROVEMENTS.md) | Every enhancement beyond the brief, with the reasoning |
| [PROMPTS.md](PROMPTS.md) | Every prompt used to build this, including the corrections |
| [CLAUDE.md](CLAUDE.md) | Working agreement for AI assistants contributing to this repo |
