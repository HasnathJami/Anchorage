# CLAUDE.md

Working agreement for Claude Code (and any other AI assistant) contributing to **Anchorage**.

Read this before touching anything. It encodes decisions that are already made, and the
reasoning behind them, so they are not silently undone.

---

## What this repository is

One repository, two independent applications, built for a Senior App Developer technical
assessment:

* **`android/`** — *Anchorage Perimeter*. Native Android, Kotlin, Jetpack Compose, Kotlin
  Flow, Hilt. Geo-fenced attendance.
* **`flutter/`** — *Anchorage Harbor*. Flutter, BLoC, get_it. Camera capture with a resilient
  upload queue.

They share a name and a design language. They share **no code**, and they must not — the
brief asks for two native-stack implementations.

---

## Commands

### Android

```bash
cd android
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"   # JDK 17 — see "The JDK" below
./gradlew testDebugUnitTest          # all 136 JVM unit tests
./gradlew testDebugUnitTest --tests "com.anchorage.perimeter.domain.*"    # one layer
./gradlew assembleDebug              # debug APK
./gradlew assembleRelease            # release APK (minified, debug-signed)
./gradlew installDebug               # build + install on a connected device
./gradlew connectedDebugAndroidTest  # 5 Compose tests; needs a device with animations off

# `./gradlew test` also works but runs the suite twice (debug + release variant),
# which is pure wall-clock on a single-module build.
```

### Flutter

```bash
cd flutter
flutter pub get
flutter analyze                      # must be clean; it currently is
flutter test                         # all unit / bloc tests
flutter test test/domain/            # one layer
flutter build apk --release
```

### The JDK — one version, and it is 17

**Both apps build on JDK 17. Not "17 or newer" — 17.** Android Studio bundles its own JBR and
moves it forward on its own schedule; a Studio update pushed the IDE's Gradle JVM to **JBR 25**,
which Gradle 8.14.3 refuses outright (*"supports Java versions between 1.8 and 24"*). The Flutter
app kept working through that, because Flutter resolves its JDK from a different setting. The two
apps had silently drifted onto different JDKs — that is the failure mode this section exists to
prevent.

Three independent places choose a JDK, and all three must agree:

| Who | Where it reads the JDK from | Value |
| --- | --- | --- |
| Android Studio / IntelliJ | `.idea/gradle.xml` → `gradleJvm` | `C:/Program Files/Android/Android Studio/jbr` |
| `flutter build` | `flutter config --jdk-dir` | `C:\Program Files\Android\Android Studio\jbr` |
| A bare `./gradlew` in a shell | `JAVA_HOME` | same path |

```bash
# check all three
"$JAVA_HOME/bin/java" -version                 # expect 17.x
flutter config --list | grep jdk-dir
grep gradleJvm .idea/gradle.xml                # .idea/ is gitignored — local only

# repair
setx JAVA_HOME "C:\Program Files\Android\Android Studio\jbr"
flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"
# IDE: Settings → Build Tools → Gradle → Gradle JVM → the JDK 17 above
```

**`jvmToolchain(17)` in both app build files is the backstop.** `android/app/build.gradle.kts`
and `flutter/android/app/build.gradle.kts` each pin it, so compilation happens on 17 even when the
launching JVM is something else. It cannot rescue the IDE from a Gradle JVM that Gradle itself
rejects at startup — the settings above are still the fix for that — but it does guarantee the two
apps never produce bytecode at different levels. Do not remove either block.

**Do not "fix" this by bumping Gradle to 9.x so it accepts JBR 25.** That drags AGP with it, and
the AGP / Kotlin / Hilt pins below exist for reasons that have not changed.

**Note on this machine:** the C: drive runs close to full. Both builds have needed
intermediate cleanup. If Gradle reports *"Failed to create parent directory"* or *"Could not
receive a message from the daemon"*, check `df -h /c` before debugging anything else — it is
almost certainly disk, not code. `GRADLE_USER_HOME=E:/anchorage-gradle-home` moves the cache
off C: if needed.

---

## Architecture: the rules that are not negotiable

### 1. Dependencies point inward, always

```
Presentation  ──►  Domain  ◄──  Data
```

Presentation and Data both depend on Domain. Domain depends on **nothing**.

On Android this is enforced by `ArchitectureTest` (`app/src/test/.../architecture/`). The app
is a **single Gradle module**; the layers are packages under `com.anchorage.perimeter`, and the
test walks the source tree and fails on the first forbidden import, naming the file. Its rules:
`domain/` imports no framework and no outer layer, `core/common/` inherits the same purity
rule, `presentation/` never reaches into `data/`, and `data/` never reaches into
`presentation/`.

**Do not delete or weaken that test, and do not delete its `the scan actually reaches the
source tree` case** — that one exists so the other five cannot pass vacuously if the layout
moves. This used to be a compiler invariant (`:core:domain` and `:core:common` were plain
`kotlin-jvm` modules that physically could not see the Android SDK); the single-module layout
traded that for one readable build file, and the test is what is holding the line now.

**Flutter is the same shape and the same guard.** `lib/` is layer-first too — `presentation/`
(with `capture/` and `sync/` inside it), `domain/`, `data/`, `core/`, `di/` — and
`test/architecture/architecture_test.dart` enforces it. There, `domain/` is on an import
**allowlist** (`dart:`, Equatable, `core/error/`, `core/result/`) rather than a denylist,
because Dart has no module boundary whatsoever and a denylist only catches the plugins someone
thought to name. Two presentation→data seams are grandfathered by name in that test; do not
add a third without writing down why.

### 2. Business rules live in the domain, never in a ViewModel or Bloc

If you find yourself writing `if (distance < 50)` or `if (hour >= 9)` in a state holder, stop.
That belongs in a policy object under `domain/policy/` or `domain/entities/`, where it is
testable on the JVM in milliseconds and cannot drift from what the use case enforces.

The state holders in this repo are deliberately thin: they translate intents into use-case
calls and project domain state onto UI state. That is all.

### 3. Failure is data, not an exception

* Kotlin: `Outcome<T>` over the sealed `AppError` hierarchy.
* Dart: `Result<T>` over the sealed `Failure` hierarchy.

**Adapters never throw.** `FusedLocationTracker`, `CameraPluginAdapter`,
`UploadQueueRepositoryImpl` and `MockUploadApi` all carry an explicit "this class never
throws" contract. Every platform exception is translated at the boundary.

When you add a failure case, add it to the sealed hierarchy. The exhaustive `when`/`switch`
in the presentation layer will then fail to compile until someone decides what the user sees
— which is the point.

### 4. Every error case must map to a different remedy

If two cases would render the same message and the same button, they should be one case.
`PermissionDenied` and `PermissionPermanentlyDenied` are separate because one offers the
system dialog and the other offers Settings. `NoConnectionFailure` and `LowBandwidthFailure`
are separate because one waits for *any* link and the other for a *better* one.

### 5. Time, randomness, dispatchers and IDs are injected

`TimeProvider`, `DispatcherProvider`, `IdGenerator`, `RetryPolicy`'s `Random`, and the
`clock` parameters on the Flutter use cases exist so tests are deterministic. Do not reach for
`DateTime.now()`, `System.currentTimeMillis()`, `Dispatchers.IO` or `Random()` directly inside
a rule.

### 6. Comments explain *why*

Never *what*. If a reader could have guessed it from the code, delete it. The existing
comments justify Haversine over `Location.distanceBetween`, full jitter over plain backoff,
`@Binds` over `@Provides`, a hand-built zoom slider over a rotated `Slider`, and reporting
rather than blocking mock locations. Match that standard.

---

## Decisions already made — do not "fix" these

| Thing | Decision | Why |
| --- | --- | --- |
| Geofence hysteresis | Entry at 50 m, exit at 58 m — on the **dial only** | GPS jitter strobes a bare threshold. The check-in itself uses the true 50 m with no forgiveness. |
| Mock locations | **Reported, not blocked** | Every emulator reports mocked fixes; blocking makes the app untestable on the device most reviewers use. |
| Map thumbnail | Procedurally drawn, seeded by coordinates | A Maps key means billing, network and a second permission surface for card decoration. |
| `permission_handler` | Pinned to **12.0.3** | 13.x requires AGP 9 / compileSdk 37 and breaks the Flutter Android build. |
| Hilt | Pinned to **2.57.2** | 2.58+ requires AGP 9. |
| Vertical zoom slider | Hand-built | A rotated Material `Slider` inverts its own gesture axis and cannot put labels inside the track. |
| Quick-zoom buttons (`0.5 / 1 / 2`) | Built from the sensor's **zoom range**, never from the count of back cameras | `availableCameras()` reports *logical* cameras: a three-lens phone publishes one rear camera spanning all three. Counting cameras collapsed the row to nothing on nearly every device. `ZoomLadder` owns the rules; do not reintroduce a lens-count check. |
| Zoom band | **0.5x - 8x**, intersected with the sensor | The 8x ceiling is a product decision (past it a phone upscales, and a 1-30x slider makes the useful band untouchable); the 0.5x floor is the hardware's to grant. `ZoomRange` owns both; do not read raw `getMinZoomLevel`/`getMaxZoomLevel` anywhere else. |
| Closing the app | Confirmed, and warns when the batch is unsent | The camera is the root route, so ✕ and back both mean *close the app*. `SystemNavigator.pop()`, never `exit(0)` - an abrupt kill can leave a half-written SQLite transaction. |
| Foreground sweep triggers | Launch, link-became-stable, **new work queued**, **backoff elapsed**, **a parked-work heartbeat** | The middle two were missing at first. The last one exists because link-became-stable is a *transition*: a weak signal that reports itself connected the whole time never produces one, and the row sat at `WAITING FOR CONNECTION` on a phone with four bars. WorkManager still covers the app-closed case, but its latency is minutes. |
| `claim` / `requeueStalled` notifications | Only when they change a row | The reaper runs at the top of every sweep; an unconditional notify plus a sweep-on-change trigger is an infinite loop. |
| Preview opens at 1x | Not at `minZoom` | On a phone whose logical rear camera spans an ultra-wide, `minZoom` is 0.5, and the app opened on a distorted wide frame nobody asked for. |
| Upload claim | Conditional `UPDATE` plus a ten-minute lease (`claimed_at`) | The WorkManager isolate has its own object graph and cannot see the foreground `_inFlight` flag. Without the claim a file uploads twice; without the lease a process killed mid-transfer strands the row in `uploading` forever. Both halves are required. |
| Mock-response switcher | In the camera's settings sheet, not the Upload Manager; **two** outcomes - `SUCCESS` and `FAILED` | A server has two answers: it took the file or it did not. `LOW BANDWIDTH` and `NO INTERNET` were removed because they are conditions of the *link*, not answers from a server, and a scripted copy of them proved nothing. `FAILED` is a retryable 500, so `RetryPolicy` stays the only thing that decides when to stop. |
| No internet | Real, from `ConnectivityMonitor` plus WorkManager's network constraint | Never scripted. Pull the device off the network and the queue parks; put it back and the queue drains. |
| Low bandwidth | Real, **measured** from the bytes moving, judged by `BandwidthPolicy` | The OS reports a transport, never a speed: one bar of GPRS is "connected" while a 300 KB photograph dies in flight. The watchdog lives in `ProcessUploadQueue` so it applies to every transport, and it parks - it does not spend an attempt, because the file and the server are both fine. |
| Flash in the settings sheet | **Removed** - the top-bar button is the only flash control | The sheet listed all four modes while the top bar already cycled them. One setting, two controls, two places to forget. The button steps the whole of `FlashPolicy.cycle`, so nothing became unreachable. Do not put it back. |
| Momentary messages | `HarborToast` at the **top**, 2.5 s for a confirmation and 4 s for a failure | `SnackBar` only anchors to the bottom, and on the camera the bottom edge is the shutter - the confirmation of a shot covered the button the user was about to press again. |
| The metering ring | Its `Stack` carries an explicit `width` | A `Stack` sizes itself from its *non-positioned* children, and the ring is positioned - so without the width the 68 dp circle was clipped to the padlock and drew as two disconnected arcs. There is a test. |
| The ring is **cut** at twelve o'clock | A `CustomPaint` arc with a gap, not a circular `BoxDecoration` | The padlock sits *in* the gap, the way every platform camera app draws it. A stroke running through the middle of a padlock reads as a broken circle with something stuck to it. `FocusReticle.lockGapSweep` derives the gap from the glyph, so it cannot drift out of step with it. |
| Tap-to-focus coordinates | Mapped through `PreviewCrop` in both directions | The preview is painted to **cover**, so a tap on screen and the point it names on the sensor are different points - on a 3:4 preview over a 9:20 screen, 40% of the sensor's width is off-glass. Passing viewport coordinates to `setFocusPoint` focused somewhere the user never touched. The reticle is drawn back out through the same crop so it lands under the finger. |
| A zoom that needs another camera | Deferred to the end of the gesture, and dispatched as its own `sequential` event | Opening a sensor blanks the preview for a few hundred milliseconds. A pinch emits dozens of values a second, so acting on each crossing of 1.0x reopened the camera over and over - and because the zoom handlers are `restartable`, a `selectLens` could be torn down half way. `CameraZoomHandoverRequested` cannot be cancelled; `CameraZoomGestureEnded` and the settle timer decide when it fires. |
| A rear-to-rear hand-over | `isSwitchingLens`, and **no** blocking overlay | A cold start has earned a spinner. A hand-over mid-pinch has not - covering the chrome for it is the flicker the deferral exists to remove. |
| Metering lock | Focus and exposure lock **together**, behind one padlock | Every camera app presents it that way, because the situation is one situation. A locked reticle also loses its dwell timer — an invisible lock is the bug this prevents. |
| Exposure compensation | Snapped to the sensor's EV grid in `ExposureRange` before anything reads it | Android rejects or silently rounds an off-grid value, and a drag produces one on nearly every frame. |
| Room `onConflict` | **ABORT**, no destructive migration fallback | A duplicate check-in is a violation to report, not to overwrite; losing an attendance log to a schema bump is a data-integrity incident. |
| Background scheduling inside the isolate | **Disabled** | Scheduling WorkManager work from inside a WorkManager task builds an accidental wake-up loop. |
| Upload concurrency | **Serial** | Parallel uploads on a weak link starve each other and blow up memory on large files. |
| Notice ownership | The location stream may not overwrite a notice raised by a user action | Fixed a real bug where the "fix too coarse" banner was wiped a fraction of a second after appearing. |

Each of these has a test, a comment, or an `IMPROVEMENTS.md` entry — usually all three. If
you believe one is wrong, change the reasoning first.

---

## Testing expectations

**Fakes over mocks for anything stateful.** A mock asserts on *calls*; a fake lets the test
assert on *behaviour*. Repositories, the queue, the network and the camera all have
hand-written fakes in `test/support/` and `src/test/.../fake/`. MockK/mocktail are used only
for one-off stubs.

**Test names are sentences.** `hysteresis is not applied to the authoritative decision`,
`a link lost mid-transfer parks rather than counts`, `a timestamp before the UTC date boundary
still lands on the local day`. A failing test should read as a statement of what broke.

**Every rule in a doc comment has a test.** `ProcessUploadQueue` lists six rules; the test
file has a group per rule. If you add a rule, add its group.

**Never assert on randomness directly.** Assert on bounds, on caps, and on variance across
seeds.

Current state: **136 Android unit tests**, **277 Flutter tests**, plus 5 Compose instrumentation
tests. `flutter analyze` is clean. Keep it that way.

---

## Design system

Both apps have a token layer. **Never put a raw colour, size or radius at a call site.**

* Android: `core/designsystem/` → `AnchorageTheme.colors/typography/shapes/spacing`.
* The office picker fetches OpenStreetMap raster tiles — the **only** outbound call in the
  Android app. It degrades to a plain grid offline; never make it a hard requirement.
* Flutter: `HarborColors` / `HarborTypography` `ThemeExtension`s, reached via
  `context.harborColors` / `context.harborText`, plus `HarborSpacing` and `HarborRadius`.

The palettes were **sampled from the reference screenshots** in `design/`, which is why they
carry values like `#2B6EEA` and `#235FEB` rather than round numbers. If you change one,
change the token, not the widget.

Accessibility rules that are already met and must stay met: no state carried by colour alone,
the distance dial is a single semantic node, buttons announce their gate, numeric read-outs
use tabular figures.

---

## When adding a feature

1. Model it in the domain first — entity, policy, port, use case. No Android or Flutter types.
2. Write the failing tests against the domain.
3. Implement the adapter in the data layer. It must not throw.
4. Add the intent/event, extend the state, extend the exhaustive notice `when`/`switch`.
5. Build it with existing design-system components; add a component only if the reference
   design actually needs a new one.
6. Update the relevant file in `docs/`, and `IMPROVEMENTS.md` if it goes beyond the brief.

## When fixing a bug

1. Reproduce it as a failing test at the layer where the rule lives.
2. Fix it.
3. If the fix encodes a non-obvious rule, name that rule in code (a predicate, a constant) and
   comment *why*, so it survives the next refactor. `isOwnedByUserAction()` is the template.

---

## Out of scope for assistants

* **Do not push to a remote or open a PR.** The repository owner handles all Git remote
  operations. Commit locally only when explicitly asked.
* **Do not add analytics, crash reporting, or any network destination.** The only outbound
  call in this codebase is a mock.
* **Do not bump AGP, Kotlin, Hilt or `permission_handler` casually.** The current pins are
  deliberate and documented above; changing them breaks a build that currently works.
