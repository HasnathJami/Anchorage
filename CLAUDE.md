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
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"   # JDK 17+; JAVA_HOME on this
                                                                 # machine points somewhere invalid
./gradlew testDebugUnitTest          # all 102 JVM unit tests
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
flutter test test/features/sync/     # one area
flutter build apk --release
```

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

**Every rule in a doc comment has a test.** `ProcessUploadQueue` lists five rules; the test
file has a group per rule. If you add a rule, add its group.

**Never assert on randomness directly.** Assert on bounds, on caps, and on variance across
seeds.

Current state: **102 Android unit tests**, **78 Flutter tests**, plus 5 Compose instrumentation
tests. `flutter analyze` is clean. Keep it that way.

---

## Design system

Both apps have a token layer. **Never put a raw colour, size or radius at a call site.**

* Android: `core/designsystem/` → `AnchorageTheme.colors/typography/shapes/spacing`.
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
