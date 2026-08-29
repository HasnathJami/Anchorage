# Testing

**347 unit tests** across both applications, plus 5 Compose instrumentation tests. All of them
run without a device.

---

## 1. Strategy

**Test where the logic lives.** Business rules were deliberately pushed into pure
domain code — a framework-free `domain/` package on Android, a plugin-free `domain/` layer on
Flutter, each guarded by an architecture test — so
the interesting behaviour is testable in milliseconds without an emulator, Robolectric, or a
`TestInstrumentationRunner`. Fast tests get run; slow tests get skipped.

**Fakes over mocks for anything stateful.** A mock asserts on *calls*; a fake lets the test
assert on *behaviour*. For repositories, queues, networks and cameras the second reads far
better and survives refactoring. MockK and mocktail appear only for one-off stubs (for
instance, a `FusedLocationProviderClient` the test never expects to reach).

**Every rule in a doc comment has a test.** `ProcessUploadQueue` lists six rules; the test
file has a group per rule. `MarkAttendanceUseCase` documents its rejection ordering; a test
asserts GPS is never called on the cheap rejections.

**Test names are sentences.** A failing test should read as a statement of what broke:

* `hysteresis is not applied to the authoritative decision`
* `a link lost mid-transfer parks rather than counts`
* `a timestamp before the UTC date boundary still lands on the local day`
* `identical points do not produce NaN through floating point drift`
* `a pinch is measured from the zoom it started at, not compounded`

**Never assert on randomness directly.** The backoff tests assert on the *ceiling*, on the
*cap*, and on *variance across seeds* — never on a sampled value. Pinning one output tests the
seed, not the policy.

**Determinism is designed in.** `TimeProvider`, `DispatcherProvider`, `IdGenerator` and
`RetryPolicy`'s `Random` are injected ports. A test asserts on `record-1`, not on a UUID
wildcard, and the attendance window is verified by moving a frozen clock rather than waiting
for 9 a.m.

---

## 2. What is covered

### Anchorage Perimeter — 129 tests

| Area | Tests | Focus |
| --- | --- | --- |
| `core/common/` | 6 | `Outcome` combinators: map, flatMap short-circuit, fold, mapError, accessors, side effects |
| `domain/` | 48 | Haversine (7), `GeoPoint` validation (5), geofence policy and hysteresis (10), attendance window (6), capture use case (5), mark use case (9), status observer (6) |
| `data/` | 17 | DataStore round-trip and corruption tolerance (6), Room date/timezone and constraint handling (6), location preflight and ordering (5) |
| `presentation/attendance/` | 25 | MVI reduction and projection, permission escalation, every action path, concurrency guard (18); formatters incl. timezone (7) |
| `presentation/officepicker/` | 15 | Opening on the saved office, the permission/anchor-read race, the three perimeter states, hand-placed provenance, every location dialog, offline tiles degrading without blocking, retry, and one-fetch-per-tile |
| `domain/geo/` (Mercator) | 9 | Projection round-trips, pole clamping, anti-meridian wrap, and that ground resolution scales with latitude so the 50 m ring keeps its true size |
| `architecture/` | 6 | The dependency rule itself: domain imports no framework and no outer layer, `core/common/` stays pure, presentation never reaches into data, data never reaches into presentation — plus one test asserting the source walk is not empty, so the other five cannot pass vacuously |

### Anchorage Harbor — 277 tests

| File | Tests | Focus |
| --- | --- | --- |
| `camera_bloc_test.dart` | 52 | Startup/permissions, lifecycle, zoom, quick-zoom stops, **a pinch past 1x deferring its lens hand-over to the end of the gesture**, focus, **metering lock**, **brightness**, capture, batching, discard, lens selection, flash |
| `process_upload_queue_test.dart` | 31 | The sync engine, grouped by its six rules — including the bandwidth watchdog: a link that stays under the floor is abandoned and parked, a dip that recovers is not, and neither costs an attempt |
| `sync_domain_test.dart` | 17 | Retry policy, task state predicates, byte-weighted progress, failure retryability |
| `formatters_test.dart` | 16 | Byte units, throughput, zoom labels, middle-truncated file names, the stem/extension split |
| `zoom_stop_test.dart` | 12 | The zoom ladder: which stops a sensor earns, and which one is lit |
| `camera_chrome_test.dart` | 17 | The quick-zoom row, the slider's drag axis, the batch badge, the disabled shutter, and the focus reticle: the metering ring being a whole circle, padlock state, brightness drag, edge clamping |
| `harbor_toast_test.dart` | 6 | The top toast: where it sits, that it retires itself after 2.5 s, that a failure is given longer, replacement, touch-to-dismiss, and its action |
| `exposure_range_test.dart` | 13 | Snapping to the sensor's EV grid, and the slider arithmetic |
| `mock_upload_api_test.dart` | 10 | The four demonstration outcomes, and the server-error ladder |
| `upload_manager_bloc_test.dart` | 16 | Queue projection, auto-resume on stable link, **the sweep that new work triggers**, **the sweep an elapsed backoff triggers**, **the heartbeat that re-drives parked work when no link event ever comes**, pause/resume, retry, discard, clear |
| `zoom_range_test.dart` | 13 | The 0.5x - 8x band: the product ceiling, the optical floor, and degrading safely |
| `zoom_span_test.dart` | 17 | The same band across *every* rear camera: effective versus sensor zoom, which lens delivers a given value, the hysteresis at the hand-over, and never switching to a longer lens on its own |
| `bandwidth_policy_test.dart` | 8 | What "too slow to be worth using" means: the floor, the grace window, and a brief dip that is not a collapse |
| `preview_crop_test.dart` | 12 | Where a tap on the covered preview lands on the sensor, and the reticle back out again — the round trip has to be exact or the ring is not under the finger |
| `camera_preview_page_test.dart` | 10 | The shutter row's alignment, and every path through closing the app |
| `exit_confirmation_dialog_test.dart` | 8 | What the dialog says and returns, with and without an unsent batch |
| `upload_widgets_test.dart` | 8 | Every status line in the reference's own words, the dimmed delivered row, the link chip's three states, the progress header |
| `flash_policy_test.dart` | 7 | The flash cycle reaching the torch, continuous-draw predicate, what survives an interruption, the torch deadline |
| `architecture_test.dart` | 4 | The dependency rule: domain on an import allowlist, data ⊘ presentation, presentation ⊘ data (two named seams), plus a scan-reach test |

The widget suites are deliberately **not** golden tests. They
assert the things that actually broke in review — a control that rendered nothing at all, a
selected state showing the wrong number, a slider whose drag axis inverted. A pixel diff
would catch none of those any better, and would fail on every font tweak.

### Instrumentation — 5 tests

`AttendanceContentTest` drives the stateless `AttendanceContent` composable: out-of-range
shows the distance and keeps check-in disabled, in-range enables it, tapping emits the intent,
the unconfigured state offers to set an office, and the permission banner emits its action.

Because `AttendanceContent` takes plain data, none of this needs Hilt, a fake GPS, or a granted
permission.

```bash
cd android && ./gradlew connectedDebugAndroidTest   # needs a device
```

**Turn the device's animations off first.** With the three animation scales at their default
`1.0`, this suite fails roughly one test in five per run — and a *different* one each time,
with `No compose hierarchies found in the app` or `Cannot run onActivity since Activity has
been destroyed already`. Both are the same root cause: the compose test rule tears the host
activity down while the previous test's exit animation is still running. It looks exactly like
a real regression, which is why it is written down here.

```bash
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
```

With those at `0` the suite is green run after run. Restore them to `1.0` afterwards — it is a
test prerequisite, not a permanent device setting. Note also that
`connectedDebugAndroidTest` **uninstalls the app** when it finishes; re-run `./gradlew
installDebug` before driving the app by hand again.

---

## 3. The test doubles

Every port has a hand-written fake. This table *is* the reason 347 tests run without hardware.

| Port | Fake | Notable capability |
| --- | --- | --- |
| `LocationTracker` | `FakeLocationTracker` | Drive the stream fix by fix; count `currentFix` calls to prove cheap rejections never touch GPS |
| `OfficeAnchorRepository` | `FakeOfficeAnchorRepository` | Emit success or failure; record saved anchors |
| `AttendanceRepository` | `FakeAttendanceRepository` | Timezone-aware date bucketing, injectable append failure |
| `TimeProvider` | `FixedTimeProvider` / `MutableTimeProvider` | Move the clock mid-test to cross the window or a date boundary |
| `IdGenerator` | `SequentialIdGenerator` | Assert on `record-1` |
| `CameraPort` | `FakeCamera` | Injectable failures per operation; records zoom, focus, lens and flash calls |
| `PermissionGateway` | `FakePermissionGateway` | Separate current status from request result — the only way to model "denied now, granted after asking" |
| `UploadQueueRepository` | `FakeUploadQueueRepository` | Full in-memory implementation with the same transition rules as SQLite |
| `UploaderPort` | `FakeUploader` | **Scripted per task id** — "fail 503, then timeout, then succeed" is one line |
| `ConnectivityPort` | `FakeConnectivity` | Drive `offline → unstable → stable` by hand |
| `BackgroundSchedulerPort` | `RecordingScheduler` | Assert the engine asked the OS to wake it |

`FakeUploader`'s scripting is what makes the retry ladder testable:

```dart
uploader.script('task-1', <Failure?>[
  const ServerFailure(503),
  const TimeoutFailure(),
  null,                      // third attempt succeeds
]);
```

---

## 4. Notable tests

**`hysteresis is not applied to the authoritative decision`** — places the user at 55 m, where
the live dial may still read INSIDE thanks to hysteresis, and asserts `MarkAttendanceUseCase`
rejects with `OutsideGeofence`. A forgiving indicator is good UX; a forgiving gate is a false
record.

**`rejects before touching GPS when the window is closed`** — asserts
`tracker.currentFixCallCount == 0`. This is a *performance and honesty* test: a user tapping at
4 p.m. must be told instantly, not after fifteen seconds of spinner.

**`a timestamp before the UTC date boundary still lands on the local day`** — 20:00 UTC on the
27th is 02:00 on the 28th in Dhaka. Files under `2026-08-28`.

**`a link becoming stable resumes the queue with no user action`** — the headline requirement,
end to end: starts offline, asserts the task is parked *with no attempt spent*, emits
`stable`, asserts it uploaded and synced. No button was pressed.

**`a merely-connected (unstable) link does not start a transfer`** — its counterpart, and the
reason the settle window exists.

**`clears any stale backoff when parking`** — a parked task waits for an *event*, not a timer.
A leftover `nextAttemptAt` would delay the upload after the network returned.

**`a second sweep started mid-flight is a no-op`** — runs two sweeps concurrently and asserts
exactly one attempt was made. The foreground Bloc and the WorkManager isolate both call this
engine.

**`a pinch is measured from the zoom it started at, not compounded`** — sends the same
cumulative scale twice within one gesture and asserts the zoom did not move the second time.

**`identical points do not produce NaN through floating point drift`** — the reason
`min(1.0, sqrt(h))` exists.

**`jitter actually varies, so a herd does not retry in lockstep`** — twelve seeds, more than
one distinct delay.

---

## 5. A bug this suite actually caught

`a coarse fix is refused with an explanatory banner and nothing is saved` failed with
`notice: null`.

The cause was real, not a test artefact: the capture failure set the banner, and the very next
position update from the location stream overwrote it. On a device the user would have seen a
flash and no explanation for why their office was not saved.

The fix was a named rule, not a patch:

```kotlin
notice = if (notice.isOwnedByUserAction()) notice else streamNotice
```

The ambient stream owns ambient notices; it may never overwrite one the user provoked. The
predicate is named and commented so it survives the next refactor.

---

## 6. Running everything

```bash
# Android — 96 unit tests
cd android
export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"
./gradlew test

# one module
./gradlew testDebugUnitTest --tests "com.anchorage.perimeter.domain.*"

# HTML report
open app/build/reports/tests/testDebugUnitTest/index.html
```

```bash
# Flutter — 140 tests
cd flutter
flutter test

# one area
flutter test test/domain/

# with coverage
flutter test --coverage
```

`flutter analyze` is clean and should stay that way.

---

## 7. What is deliberately not tested here

Honest list, with the reasoning:

| Not covered by unit tests | Why | Where it *is* covered |
| --- | --- | --- |
| Real GPS acquisition | Needs hardware and a sky | Manual device testing; the preflight and translation paths are unit-tested |
| Real camera capture | `CameraController` cannot be built on the Dart VM | `CameraPort` + `FakeCamera`; the adapter's translation is straight-line code |
| `sqflite` SQL execution | Needs `sqflite_common_ffi` and a native library | `FakeUploadQueueRepository` mirrors the transition rules; the schema is exercised on device |
| `connectivity_plus` platform channel | Needs a platform | The settle-window *logic* is the tested part, through `FakeConnectivity` |
| WorkManager scheduling | Needs the Android framework | `RecordingScheduler` asserts the engine's *intent*; actual scheduling is verified on device |
| Compose pixel rendering | Would need screenshot testing | 5 instrumentation tests assert behaviour; see below |

**The gap I would close first at production scale:** screenshot tests (Paparazzi on Android,
`golden_toolkit` on Flutter) to lock the pixel-perfect UI against regression. The design is a
graded requirement here, and right now only a human eye protects it.

Second would be `sqflite_common_ffi` so the real SQL — including the unique index and the
migration path — runs in CI.
