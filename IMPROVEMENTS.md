# Improvements

> The brief says: *"If our candidates have a better approach or idea that can make the task
> outstanding on a technical level or feature-wise, we will always welcome and appreciate
> your efforts and creativity."*

This document is the answer to that invitation. Everything below goes **beyond** the literal
requirements. Each entry states what the brief asked for, what Anchorage does instead, and —
most importantly — **why**, because an improvement without a reason is just extra surface
area.

Nothing here was added for decoration. Every one of these exists because the naive
implementation of the requirement has a specific, demonstrable failure mode on a real device.

---

## Contents

**Task 1 — Anchorage Perimeter**
1. [Geofence hysteresis (a Schmitt trigger for GPS)](#1-geofence-hysteresis)
2. [Accuracy is a first-class concept, not metadata](#2-accuracy-is-a-first-class-concept)
3. [A stricter bar for anchoring than for checking in](#3-a-stricter-bar-for-anchoring-than-for-checking-in)
4. [The check-in is re-validated with a fresh fix](#4-the-check-in-is-re-validated-with-a-fresh-fix)
5. [The attendance window is enforced, not decorated](#5-the-attendance-window-is-enforced)
6. [Mock-location detection — reported, deliberately not blocked](#6-mock-location-detection)
7. [Once-per-day enforced by a database constraint](#7-once-per-day-enforced-by-the-database)
8. [An audit trail that freezes distance and accuracy](#8-an-audit-trail-that-freezes-the-evidence)
9. [Permission "denied" vs "blocked" are different screens](#9-denied-and-blocked-are-different-screens)
10. [Persistent banners instead of transient toasts](#10-persistent-banners-instead-of-toasts)
11. [A procedurally generated map thumbnail — no Maps API key](#11-a-procedurally-generated-map-thumbnail)
12. [The GPS stream is started and stopped explicitly](#12-the-gps-stream-is-started-and-stopped-explicitly)
13. [Notice ownership: the stream cannot erase what you provoked](#13-notice-ownership)
14. [Attendance history screen](#14-attendance-history-screen)
15. [Timezone-correct "today"](#15-timezone-correct-today)

**Task 2 — Anchorage Harbor**
16. [Link *quality*, not link *presence* — the settle window](#16-link-quality-not-link-presence)
17. [Connectivity failures do not consume retry attempts](#17-connectivity-failures-do-not-consume-attempts)
18. [Exponential backoff with full jitter](#18-exponential-backoff-with-full-jitter)
19. [Retryable and permanent failures are distinguished](#19-retryable-and-permanent-failures-are-distinguished)
20. [Two background jobs, for two different reasons](#20-two-background-jobs-for-two-different-reasons)
21. [The background isolate returns an honest verdict to the OS](#21-an-honest-verdict-to-the-os)
22. [A mock API that actually exercises the engine](#22-a-mock-api-that-actually-exercises-the-engine)
23. [The real HTTP transport, written out and commented out](#23-the-real-transport-written-out)
24. [An in-app mock-response switcher](#24-an-in-app-mock-response-switcher)
25. [Progress measured in bytes, not item count](#25-progress-measured-in-bytes)
26. [Captured files are moved out of the cache immediately](#26-captured-files-leave-the-cache-immediately)
27. [The camera sensor is released on pause](#27-the-sensor-is-released-on-pause)
28. [Declared Bloc concurrency: droppable shutter, restartable zoom](#28-declared-bloc-concurrency)
29. [Pinch zoom anchored to the gesture's origin](#29-pinch-zoom-anchored-to-the-gestures-origin)
30. [Quick-zoom stops built from the sensor's range, not the camera count](#30-quick-zoom-stops-built-from-the-sensors-range-not-the-camera-count)
30a. [The batch review sheet — a last free moment to drop a frame](#30a-the-batch-review-sheet--a-last-free-moment-to-drop-a-frame)
30b. [Closing the app is a question, not an accident](#30b-closing-the-app-is-a-question-not-an-accident)
30c. [The zoom band is a decision, and the shutter is actually centred](#30c-the-zoom-band-is-a-decision-and-the-shutter-is-actually-centred)
30d. [Tap-to-focus that is a control, not a decoration](#30d-tap-to-focus-that-is-a-control-not-a-decoration)
31. [Serial uploads, and a re-check between files](#31-serial-uploads-and-a-re-check-between-files)
32. [An in-flight guard, and the claim that the guard cannot replace](#32-an-in-flight-guard-and-the-claim-that-the-guard-cannot-replace)
32a. [Four reasons to sweep, not one](#32a-four-reasons-to-sweep-not-one)
33. [Manual retry resets the attempt budget](#33-manual-retry-resets-the-budget)
34. [Pause / resume that the engine actually respects](#34-pause-and-resume)

**Cross-cutting**
35. [A closed error taxonomy the compiler polices](#35-a-closed-error-taxonomy)
36. [Injectable clocks, dispatchers, randomness and IDs](#36-injectable-clocks-dispatchers-randomness)
37. [Design tokens transcribed from the reference, not eyeballed](#37-tokens-transcribed-not-eyeballed)
38. [Accessibility: state is never carried by colour alone](#38-accessibility)
39. [Attendance and queue data excluded from cloud backup](#39-data-excluded-from-cloud-backup)
40. [Documentation as a deliverable](#40-documentation-as-a-deliverable)
41. [The dependency rule is a test, not a convention](#41-the-dependency-rule-is-a-test-not-a-convention)
42. [The flash was decorative; now it works, and it has a deadline](#42-the-flash-was-decorative-now-it-works-and-it-has-a-deadline)
43. [Two platform round-trips per pinch frame, removed](#43-two-platform-round-trips-per-pinch-frame-removed)
44. [The office is placed on a map, not grabbed blind](#44-the-office-is-placed-on-a-map-not-grabbed-blind)

---

# Task 1 — Anchorage Perimeter

## 1. Geofence hysteresis

**Brief:** *"only be enabled/functional if the user's current location is within a 50-meter
radius."*

**Naive implementation:** `if (distance < 50) enable()`.

**Why that fails:** a user standing still exactly on the boundary produces GPS readings that
jitter by several metres every second. The button strobes between enabled and disabled, the
dial flickers red/green, and — worst — the button can become disabled *between the user
deciding to tap it and their finger landing*.

**What Anchorage does:** a Schmitt trigger. Entering the fence requires ≤ 50 m; leaving it
requires > 58 m (`radius + exitHysteresisMeters`). The threshold you must cross depends on
which side you are already on.

```kotlin
val threshold = if (previousStatus == INSIDE) policy.exitRadiusMeters else policy.radiusMeters
val status = if (distance <= threshold) INSIDE else OUTSIDE
```

The state is threaded through the Flow with `scan`, not held in a mutable field, so it stays
pure and testable.

**Note the deliberate asymmetry:** hysteresis applies to the *live dial* only.
`MarkAttendanceUseCase` judges the actual check-in against the true 50 m radius, with no
hysteresis. A forgiving indicator is good UX; a forgiving gate is a false attendance record.
There is a test named exactly that: *"hysteresis is not applied to the authoritative
decision"*.

**Where:** `GeofenceEvaluator`, `GeofencePolicy.exitHysteresisMeters`.

---

## 2. Accuracy is a first-class concept

**Brief:** silent on accuracy.

**Why it matters:** `Location.accuracy` is the radius of a 68 % confidence circle. Indoors it
is routinely 50–150 m. A fix that says "you are 12 m from the office, ± 90 m" tells you
essentially nothing — but a naive app will happily unlock the button on it, and the user will
be marked present from the car park across the road.

**What Anchorage does:** `LocationFix.accuracyMeters` is part of the domain model, and
`GeofenceReading` carries `isConfident` **separately from** `status`. The UI has a distinct
`WEAK SIGNAL` state in amber that says exactly what is wrong:

> *"The signal is accurate to about ±90 m, which is wider than the 50 m perimeter. Waiting
> for a better fix."*

A fix with no accuracy claim at all is treated as `Float.MAX_VALUE` — maximally untrustworthy
rather than perfect. Failing closed is the only safe default for a value that gates a
check-in.

**Where:** `GeofenceReading.isConfident`, `ProximityUi.LowConfidence`,
`FusedLocationTracker.UNKNOWN_ACCURACY_METERS`.

---

## 3. A stricter bar for anchoring than for checking in

**Why:** the anchor's own error is inherited by *every future comparison*. Saving a 120 m-
accurate fix silently turns the 50 m geofence into a coin toss for the lifetime of the
install, and the user has no way to know.

**What Anchorage does:** two thresholds. Checking in tolerates ± 50 m; anchoring demands
± 35 m. A rejection is loud and carries the actual numbers:

> *"The reading was accurate to ±120 m but anchoring an office needs ±35 m or better,
> otherwise the 50 m perimeter would be meaningless."*

**Where:** `GeofencePolicy.maxAnchorAccuracyMeters`, `CaptureOfficeAnchorUseCase`.

---

## 4. The check-in is re-validated with a fresh fix

**Why:** a disabled button is a UI *affordance*, not an enforcement boundary. Between the
frame being rendered and the tap landing, the user can walk out of the fence, the clock can
cross 10:30, or a second device can record the day. And the streamed position may be stale —
the OS throttles updates aggressively when an app is backgrounded.

**What Anchorage does:** `MarkAttendanceUseCase` re-checks **every** gate and acquires a
**fresh** high-accuracy fix at the moment of tapping. One deliberate round-trip costs about a
second and removes an entire class of bug.

The rejections are ordered cheapest-first: window, then anchor, then duplicate, and only then
the expensive GPS acquisition. A user tapping at 4 p.m. is told why instantly rather than
watching a spinner for fifteen seconds first.

**Where:** `MarkAttendanceUseCase`.

---

## 5. The attendance window is enforced

**Why:** the reference design prints `AVAILABLE 09:00 AM - 10:30 AM` under the button. An app
whose own UI makes a promise it does not keep is worse than one that never made it.

**What Anchorage does:** `AttendanceWindow` is a real domain policy. `canMarkAttendance`
includes it, `MarkAttendanceUseCase` rejects outside it with `WindowClosed`, and the caption
flips to `WINDOW CLOSED · 09:00 AM - 10:30 AM` in amber. Both ends are inclusive, because
"closes at 10:30" reads to a human as "10:30 still works".

**Where:** `AttendanceWindow`, `AttendanceStatus.canMarkAttendance`.

---

## 6. Mock-location detection

**What Anchorage does:** every `LocationFix` carries `isMock`, propagated to
`GeofenceReading.isMockProvider`, and surfaces an amber banner:

> *"This device is reporting a simulated position. The check-in will still work and is
> recorded as such."*

**The deliberate decision not to block.** Blocking mock locations is the obvious
"anti-cheat" move and it is the wrong one here: **every Android emulator reports every fix as
mocked**. Blocking would make the app untestable on the exact device most reviewers will
use — and a determined spoofer defeats client-side checks anyway. Surfacing it keeps the
audit trail honest without making the app unusable.

That reasoning is written into the code, not just here, so the next developer does not
"fix" it.

**Where:** `AttendanceNotice.MockLocationActive`, `FusedLocationTracker.isMockLocation()`.

---

## 7. Once-per-day enforced by the database

**Why:** an application-level `if (alreadyMarked) return` loses to a race. Two coroutines, a
double-tap that slips past the busy guard, a background job — any of them can produce two
rows.

**What Anchorage does:** `AttendanceEntity` denormalises the local calendar date into an
indexed column with a **unique index**, and the DAO inserts with
`OnConflictStrategy.ABORT`. SQLite is the enforcement point. The repository catches
`SQLiteConstraintException` and translates it into `AppError.Attendance.AlreadyMarked`
carrying the *existing* record's timestamp.

ABORT rather than REPLACE, deliberately: a duplicate is a rule violation the caller must
learn about, not something to paper over by overwriting the earlier — and more truthful —
record.

**Where:** `AttendanceEntity`, `AttendanceDao.insert`, `AttendanceRepositoryImpl.append`.

---

## 8. An audit trail that freezes the evidence

**Why:** a record holding only a timestamp is unfalsifiable later, when the office anchor may
already have been moved.

**What Anchorage does:** `AttendanceRecord` freezes the coordinate, the measured distance,
the fix accuracy and the anchor label *at the moment of marking*. Six months later you can
still answer "how close were they, and how sure were we?".

**Where:** `AttendanceRecord`.

---

## 9. "Denied" and "blocked" are different screens

**Why:** these are the same boolean to `RequestMultiplePermissions` and completely different
situations for the user. Repeatedly showing "Grant permission" to someone whose OS will never
show the dialog again is a dead end.

**What Anchorage does:** reads `shouldShowRequestPermissionRationale` **after** the dialog
closes to tell them apart, and changes the banner's offer accordingly:

| State | Message | Action |
| --- | --- | --- |
| `PermissionRequired` | "Anchorage needs your location to tell whether you are at the office." | **Grant permission** → system dialog |
| `PermissionBlocked` | "Android will not ask again." | **Open settings** → app settings deep link |
| `LocationServicesOff` | "Turn on device location…" | **Turn on location** → location settings |

The rationale flag is read by walking the `ContextWrapper` chain to find the Activity, rather
than assuming the composition's context is one — it is not, when hosted in a `ComposeView`.

**Where:** `AttendanceIntent.PermissionResult`, `shouldShowLocationRationale()`.

---

## 10. Persistent banners instead of toasts

**Why:** "permission missing", "location switched off", "signal too weak" are *persistent
states*, not momentary events. A Snackbar vanishes in four seconds and leaves a screen that
looks inexplicably inert.

**What Anchorage does:** an inline `AnchorageBanner` that stays until the condition clears,
**always carrying an action**. A message that names a problem without offering the fix is
half an answer. Momentary rejections (outside geofence at tap time, window closed) do get a
Snackbar, because they *are* events.

**Where:** `AnchorageBanner`, `NoticeBanner`, `AttendanceEffect.ShowMessage`.

---

## 11. A procedurally generated map thumbnail

**Why:** the reference card shows a map. A real `MapView` means a billed API key, a network
round-trip, a heavyweight dependency and a second permission surface — for what is decoration
inside a card.

**What Anchorage does:** draws the tile procedurally on a `Canvas`, **seeded from the
anchor's own coordinates**. The same office always renders the same street pattern; two
different offices look visibly different. The "this is your saved place" signal survives with
zero dependencies, zero network and zero cost.

**Where:** `MiniMapPreview`.

---

## 12. The GPS stream is started and stopped explicitly

**Why:** location streaming is the single most expensive thing the app does.
`stateIn(WhileSubscribed)` would keep the GPS warm whenever *anything* happened to hold a
reference to the flow.

**What Anchorage does:** an explicit `observationJob` that runs only while the screen holds
permission, cancelled in `onCleared()` and whenever permission is lost.

**Where:** `AttendanceViewModel.startObserving` / `stopObserving`.

---

## 13. Notice ownership

**The bug this fixes** (found by a failing test, not by inspection): the anchor-rejected
banner appeared and was wiped by the very next position update — a fraction of a second
later. The user saw a flash and no explanation.

**The rule now:** the ambient location stream owns ambient notices and may replace or clear
them freely, but it may **never** overwrite one raised by the permission flow or by an
explicit user action.

```kotlin
notice = if (notice.isOwnedByUserAction()) notice else streamNotice
```

**Where:** `AttendanceViewModel.reduce`, `isOwnedByUserAction`.

---

## 14. Attendance history screen

**Why:** a geofenced check-in that leaves no reviewable record is half a feature. The whole
point of freezing distance and accuracy into every record is that somebody can look at them
later.

**What Anchorage does:** a history route reachable from the app bar, showing date, time,
distance and anchor label per record.

**Where:** `AttendanceHistoryRoute`, `ObserveAttendanceHistoryUseCase`.

---

## 15. Timezone-correct "today"

**Why:** a 2 a.m. check-in in Dhaka is 20:00 UTC *the previous day*. Storing or comparing in
UTC files it against the wrong day and breaks the once-per-day rule twice over.

**What Anchorage does:** the repository derives the local calendar date through an injected
`TimeProvider.zone()`, and "today" is recomputed on **every** emission rather than captured at
subscribe time — so a session left open across midnight re-arms correctly instead of
reporting yesterday's check-in.

There is a test for exactly this: *"a timestamp before the UTC date boundary still lands on
the local day"*.

**Where:** `AttendanceRepositoryImpl`, `ObserveAttendanceStatusUseCase.reduce`.

---

# Task 2 — Anchorage Harbor

## 16. Link quality, not link presence

**Brief:** *"Automatically retry the upload once a stable connection is detected."*

**The word that matters is "stable".** `connectivity_plus` reports a link the instant the OS
associates with a network — typically several seconds before it can carry a byte (DHCP,
captive-portal checks, a train leaving a tunnel with one bar). An engine that starts
uploading on the first `connected` event fails immediately and burns a retry attempt, every
single time.

**What Anchorage does:** three states, not two.

| State | Meaning | Engine behaviour |
| --- | --- | --- |
| `offline` | No transport | Park everything |
| `unstable` | Transport exists but has not held long enough | Park everything |
| `stable` | Held continuously for the settle window (3 s) | Transfer |

A new link is admitted as `unstable` and *promoted* by a timer that any drop cancels.
Demotion is instant. Being pessimistic quickly and optimistic slowly is the right asymmetry
when the cost of a false "stable" is a wasted attempt.

**Where:** `ConnectivityMonitor`, `LinkQuality`.

---

## 17. Connectivity failures do not consume attempts

**Brief:** *"If the API call fails due to low bandwidth or no internet, the images must remain
in the local queue."*

**Why the obvious reading is not enough:** keeping the file is necessary but not sufficient.
If losing signal counts as a failed attempt, five tunnels exhaust the retry budget and the
photograph is marked permanently failed — while sitting on a perfectly good phone with a
perfectly good file.

**What Anchorage does:** a missing network is a **pause**, not a failure. The task moves to
`waitingForConnection`, its attempt counter is untouched, and the stale backoff deadline is
*cleared* — a parked task waits for an event, not a timer, and leaving a backoff on it would
delay the upload after the network returned.

Tests: *"parks every task and spends no attempt when offline"*, *"a link lost mid-transfer
parks rather than counts"*, *"clears any stale backoff when parking"*.

**Where:** `ProcessUploadQueue`, `UploadQueueRepository.parkForConnectivity`.

---

## 18. Exponential backoff with full jitter

**Why plain exponential backoff is not enough:** twelve photographs fail together the moment
a tunnel swallows the signal. With deterministic backoff all twelve wake at exactly the same
millisecond, hit the server together, and — if the server was the problem — knock it over
again.

**What Anchorage does:** full jitter. The delay is uniform in `[0, computed]` where
`computed = 4 s × 2^(attempt-1)`, capped at 15 minutes. This is the AWS-documented variant
that minimises both collision and total wait.

The `Random` is injected, so backoff is deterministic under test — and the tests assert on
the *ceiling* and on the *variance*, not on a sample, which is the correct way to test a
randomised policy.

**Where:** `RetryPolicy.delayForAttempt`.

---

## 19. Retryable and permanent failures are distinguished

**Why:** retrying a 400 five times with exponential backoff is a battery drain that ends in
the same failure. A queue entry pointing at a file the OS has deleted will never succeed no
matter how long you wait.

**What Anchorage does:** a single predicate, `Failure.isRetryable`, exhaustively defined over
the closed taxonomy. `MissingArtifactFailure` and a non-retryable `ServerFailure` fail on the
**first** attempt and are surfaced with a per-row retry/discard control.

**Where:** `FailureRetryability`, `ProcessUploadQueue` rule 4.

---

## 20. Two background jobs, for two different reasons

**Brief:** *"Implement a background worker (e.g. workmanager) to monitor connectivity."*

**What Anchorage does:**

* **Periodic sweep** (15 min, the OS minimum, `ExistingPeriodicWorkPolicy.keep`) — the safety
  net. It exists for the case where the app is never opened again: the photographs still
  leave the device.
* **Opportunistic one-shot** with a `NetworkType.connected` constraint — this is the piece
  that satisfies "retry once a connection is detected" *properly*. The **OS itself** watches
  the radio and wakes the app. That is dramatically cheaper and more reliable than an
  in-process listener, which dies with the app.

`ExistingWorkPolicy.keep` on the one-shot is deliberate: enqueueing a batch of twelve
photographs must schedule **one** wake-up, not twelve.

Ordering also matters — `EnqueueBatch` commits rows to SQLite *before* asking the OS for a
wake-up. Reversed, the worker could run, find an empty queue and go back to sleep.

**Where:** `WorkManagerScheduler`, `EnqueueBatch`.

---

## 21. An honest verdict to the OS

**Why:** `executeTask` returning `true` means "done, do not wake me again". Returning `true`
after a failure is *the* reason most background-sync implementations quietly stop working
after the first bad network.

**What Anchorage does:** the one-shot task returns `!report.shouldReschedule` — i.e. `false`
(retry me) while work genuinely remains. The periodic task always returns `true`, so its own
cadence is preserved.

Background scheduling is also **disabled inside the isolate** (`enableBackgroundScheduling:
false`): asking WorkManager to schedule more work from inside a WorkManager task is how you
build an accidental wake-up loop. The intent is expressed through the return value instead.

Nothing is allowed to throw out of the isolate either — an escaped exception is reported as a
crash and can get the app's background execution throttled by the OS.

**Where:** `syncCallbackDispatcher`.

---

## 22. A mock API that actually exercises the engine

**Brief:** *"use mock API Responses for Success and Failed hard-codedly."*

**What Anchorage does:** `MockUploadApi` is a *working transport*, not a stub that returns
`true`. It streams realistic progress at a configurable throughput, fails at a configurable
fraction of the file, and returns the whole typed failure taxonomy:

| Behaviour | Produces |
| --- | --- |
| `succeed` | Full transfer, then success |
| `failLowBandwidth` | `LowBandwidthFailure` **mid-transfer** (45 % in) |
| `failNoConnection` | `NoConnectionFailure` before any bytes move |
| `failServerRetryable` | `ServerFailure(503)` |
| `failServerPermanent` | `ServerFailure(400, isRetryable: false)` |
| `hang` | Never answers; the caller's timeout fires |
| `flaky` | A weighted random mix — soak-testing |

Failures happen **part-way through**, not at byte zero, because that is the case that
exercises partial-transfer handling. It also honours the *real* link when one is wired in, so
pulling a device off Wi-Fi during a demo produces a genuine failure rather than a scripted
one.

**Where:** `MockUploadApi`.

---

## 23. The real transport, written out

The brief permits "commenting out the API Call methods and classes". Anchorage does both —
`http_upload_api.dart` contains the full production implementation, commented out, so a
reviewer can see exactly what would ship. It is not a sketch; it includes the details that
matter for a resilient client:

* a **streamed** multipart body, so a 1.2 GB file never sits in memory;
* an **idempotency key**, so a retry after an ambiguous timeout cannot create a duplicate
  server-side record;
* status-code classification (408/429/5xx retryable, other 4xx permanent);
* a socket-level catch mapping to `NoConnectionFailure`, which the engine treats as *park*,
  not *attempt spent*.

Switching is one line in `injector.dart`.

**Where:** `http_upload_api.dart`.

---

## 24. An in-app mock-response switcher

**Why:** a reviewer should be able to *see* the resilience, not take the README's word for it.

**What Anchorage does:** two chips inside the camera's **⚙ settings sheet** switch what the
mock *server* says. Tap **FAILED** and watch `RETRYING... (ATTEMPT 2/5)` climb with jittered
backoff until the row lands at `FAILED` with a manual retry.

The switcher used to carry **NO INTERNET** and **LOW BANDWIDTH** as well, and dropping them
made the demonstration stronger rather than weaker. Both are conditions of the *link*, and a
scripted link proves nothing about an app's resilience — it proves the script works. They are
now read from the device: connectivity from `ConnectivityMonitor`, and bandwidth **measured**
from the bytes actually moving and judged by `BandwidthPolicy`. Turn off mobile data and the
rows park with no attempt spent; turn it back on and they drain. Stand somewhere with one bar
and the same thing happens for a link that never technically dropped.

It began at the bottom of the Upload Manager and moved when that screen was brought back in
line with the reference design, whose bottom bar carries one button and nothing else. A
demonstration affordance is not worth a permanent deviation from the design it is meant to
demonstrate.

Nothing in the engine reads it, and swapping in the real transport makes it render nothing at
all — the widget checks whether `MockUploadApi` is even registered.

**Where:** `CameraSettingsSheet._MockTransportSection`.

---

## 25. Progress measured in bytes

**Why:** one 1.2 GB scan among four thumbnails would read as "80 % done" the moment the
thumbnails land, and then sit at 80 % for ten minutes.

**What Anchorage does:** `BatchProgress.fraction` is computed over bytes. A synced task counts
its *full* size even if the last progress tick was lost, so the bar always reaches the end
when the queue drains. Progress is **derived from the queue**, never tracked separately, so
the header can never disagree with the rows beneath it.

**Where:** `BatchProgress.from`.

---

## 26. Captured files leave the cache immediately

**Why:** the `camera` plugin writes to the app's *cache* directory, which the OS may clear at
any moment under storage pressure. A queued upload must still find its bytes tomorrow
morning.

**What Anchorage does:** every capture is copied into app-private documents storage
(`captures/`) and the cache copy is deleted, before the shot ever reaches the batch.

**Where:** `CameraPluginAdapter.capture`.

---

## 27. The sensor is released on pause

**Why:** Android hands the camera to whichever app asked most recently. Holding it while
backgrounded means a phone call leaves the user staring at a frozen black rectangle on return
— the single most common bug in Flutter camera apps.

**What Anchorage does:** `CameraPreviewPage` is a `WidgetsBindingObserver`; pause disposes the
controller and resume re-opens it. `CameraSession.previewKey` increments on every re-open, so
the widget rebuilds against the new controller rather than a disposed texture. Resume also
**re-checks permission**, because it can have been revoked from Settings while the app was
away.

**Where:** `CameraBloc._onPaused` / `_onResumed`, `previewKey`.

---

## 28. Declared Bloc concurrency

**Why:** the default event transformer is `concurrent()`, which for a shutter button means a
user hammering it queues twelve captures.

**What Anchorage does:** concurrency is declared per event, not hoped for.

| Event | Transformer | Reason |
| --- | --- | --- |
| Shutter | `droppable()` | One photograph per completed capture |
| Zoom / pinch / focus | `restartable()` | Only the newest value matters; a pinch emits dozens per second |
| Everything else | `sequential()` | Lifecycle and lens changes must not interleave |

**Where:** `CameraBloc` constructor.

---

## 29. Pinch zoom anchored to the gesture's origin

**Why:** `ScaleUpdateDetails.scale` is cumulative *for the gesture*. Multiplying it by the
*current* zoom every frame compounds, and the preview rockets to maximum from the smallest
pinch.

**What Anchorage does:** `CameraPinchStarted` records the zoom the gesture began at; each
update computes `baseZoom × scale`. Single-finger pans (`pointerCount < 2`) are ignored, so
tap-to-focus never nudges the zoom.

There is a test for exactly this: *"a pinch is measured from the zoom it started at, not
compounded"*.

**Where:** `CameraBloc._pinchBaseZoom`.

---

## 30. Quick-zoom stops built from the sensor's range, not the camera count

**Why:** the obvious implementation of `0.5 / 1 / 2` is one button per rear camera, and the
obvious guard is "hide the row when there is only one". Both are reasonable. Together they
made the reference design's most recognisable control render as **empty space on nearly every
device**, and that is how it shipped in the first version.

`availableCameras()` reports *logical* cameras. A phone with an ultra-wide, a main and a
telephoto typically publishes one rear camera whose zoom range spans all three, and lets the
platform swap the physical sensor underneath as the zoom crosses a threshold. So the count was
one, the row collapsed, and there was nothing on screen to notice — the failure mode of a
control that renders nothing is that it looks like a design choice.

**What Anchorage does:** `ZoomLadder` derives the row from the sensor's real zoom range.
1x is always present; a wide button is earned only by a minimum genuinely below 1x and targets
that exact minimum, so a 0.6x ultra-wide is labelled `0.6` and lands where the hardware stops
instead of being clamped; 2x/3x/5x/10x appear only up to what the sensor reaches, capped at
three buttons. The selected pill shows the *live* zoom (`1.7x`) whenever the value sits
between stops, which turns the row into an always-correct read-out.

Physical lens switching survives for the devices that do publish each rear sensor separately:
`CameraZoomStopSelected` opens the nearest rear camera **only** when the open one cannot reach
the requested ratio.

The adapter also opens at **1x rather than `minZoom`** — on an ultra-wide-spanning sensor the
minimum is 0.5, and the app used to open on a distorted wide frame nobody had asked for.

**Where:** `domain/entities/zoom_stop.dart`, `CameraBloc._onZoomStopSelected`,
`ZoomStopSelector`, `CameraPluginAdapter._open`.
**Tests:** 12 in `zoom_stop_test.dart`, 3 in `camera_bloc_test.dart`, 4 in
`camera_chrome_test.dart` — including *"a single rear camera that can zoom still gets a row of
stops"*, which fails against the old implementation.

---

## 30a. The batch review sheet — a last free moment to drop a frame

**Why:** once a batch reaches the queue it is *durable*. Those photographs are retried across
reboots and eventually cost real bandwidth on a metered link. A field operator who knows two
of fourteen frames are blurred should not have to pay to deliver them.

`CameraShotDiscarded` had been modelled since the first version of this Bloc and was reachable
from no UI whatsoever — a rule with no way to invoke it.

**What Anchorage does:** tapping the corner thumbnail opens `BatchReviewSheet`, a grid of the
shots that have **not** been handed over, where tapping one drops it. The sheet closes itself
when the last frame goes, and with an empty batch the thumbnail goes to the Upload Manager
instead.

Discarding deletes the **file**, not just the list entry. The photograph is on disk the
instant the shutter fires — that ordering is the app's whole durability story — so a discard
that only forgot the entry would leave every rejected frame on the device for good.

**Where:** `BatchReviewSheet`, `CameraPort.discard`, `CameraBloc._onShotDiscarded`.
**Tests:** *"a discarded shot leaves the batch and the disk"*, *"discarding a shot that is not
in the batch deletes nothing"*.

---

## 30b. Closing the app is a question, not an accident

**Why:** a confirmation on exit is usually friction for its own sake. This one earns it.
Photographs live in the working batch from the moment the shutter fires until **UPLOAD
BATCH** hands them to the queue — and only the queue is durable. Closing with an unsent batch
strands those frames on the device, outside the engine that would have delivered them, and
nothing tells the user that happened.

It also repairs a defect. The ✕ called `Navigator.maybePop()`, and the camera is the app's
root route: there was nothing to pop, so the button did nothing at all. No error, no
animation, no clue — it simply looked disabled.

**What Anchorage does:** the ✕ and the system back gesture both route through one
confirmation (`PopScope(canPop: false)` intercepts the platform back, so the two cannot
diverge). The dialog adapts: an empty batch gets `CLOSE` / `CANCEL` and a note that the queue
keeps syncing in the background; an unsent batch is counted, warned about, and offered
`UPLOAD & CLOSE`, which enqueues first and closes second — and **declines to close** if the
enqueue fails. Dismissing the dialog counts as *cancel*, because not answering a question is
not consent.

`SystemNavigator.pop()`, never `exit(0)`: the platform finishes the activity so Flutter and
the plugins shut down in order, rather than a kill that can leave a half-written SQLite
transaction behind.

**Where:** `ExitConfirmationDialog`, `_CameraPreviewPageState._requestExit`.
**Tests:** 8 in `exit_confirmation_dialog_test.dart`, 6 in `camera_preview_page_test.dart`.

---

## 30c. The zoom band is a decision, and the shutter is actually centred

**Why (the band):** `getMaxZoomLevel` returns whatever the driver claims — 10x, 30x, more.
Handing that straight to the UI is not neutrality, it is an unmade decision: past roughly 8x
a phone upscales rather than zooms, and mapping 1x–30x onto the reference's ~230 dp slider
leaves the 1x–3x band people actually use about twenty pixels tall.

**What Anchorage does:** `ZoomRange.fromSensor` intersects the offered band (0.5x – 8x) with
what the sensor admits, once, when the camera opens. The ceiling is enforced; the floor is
the hardware's to grant, because you cannot see wider than the lens. Everything downstream
reads that one value instead of the raw platform numbers.

**Why (the alignment):** the shutter row used `MainAxisAlignment.spaceBetween`, which reads
as symmetrical and is not — with a 62 dp thumbnail on one side and a 44 dp flip button on the
other, the shutter sat 9 dp right of centre. The thumbnail also hung 4 dp low, because its
box was padded at the top to make room for the count badge.

**What Anchorage does:** matching `Expanded` slots flank the shutter, so its centring is
exact whatever the neighbours weigh; and the thumbnail's box *is* its visible square, with
the badge overhanging rather than boxed in. Both are pinned by tests that measure the rects,
because "looks centred" is exactly the class of thing that drifts back.

**Where:** `domain/entities/zoom_range.dart`, `_ChromeOverlay`, `BatchThumbnail`.
**Tests:** 13 in `zoom_range_test.dart`, 2 in `camera_preview_page_test.dart`.

---

## 30d. Tap-to-focus that is a control, not a decoration

**Brief:** *"Manual Focus: tap-to-focus functionality with a visual indicator at the tap
point."*

**Naive implementation:** draw a square where the user tapped, fade it out.

**Why that is not enough:** the indicator answers "did my tap register?" and nothing else.
Every situation that makes a person tap the viewfinder in the first place — a subject against
a bright window, a document on a dark desk, a frame they want to keep while they move — needs
two more things: the ability to *hold* what was just metered, and the ability to say *brighter
than that*.

**What Anchorage does:** the reticle is modelled on the platform camera apps, because the
familiarity is the feature. A ring marks the metering point; a padlock on the ring holds
focus **and** exposure; a sun on a track below sets exposure compensation.

Focus and exposure lock together behind one padlock. The hardware exposes them separately,
but the situation the control exists for is one situation — *I have framed this, stop
changing it* — and splitting them would be more faithful to the hardware and less faithful to
the intent. The adapter locks exposure *first*: locking focus is instant, but locking exposure
mid-convergence bakes in whatever brightness the sensor happened to be passing through, and
the visible result is a frame that darkens the moment the padlock closes.

Three rules keep it honest:

1. **A locked reticle does not fade.** An invisible lock is the failure mode here: the user
   forgets they set it and every photograph afterwards is metered for a subject they walked
   away from.
2. **A tap elsewhere releases it** and returns the brightness to neutral — both belonged to
   the old point.
3. **Nothing survives invisibly.** The reticle fading returns the exposure to 0 EV; releasing
   the sensor drops the lock, because a new controller starts at auto.

The dwell went from 1.2 s to **4 s**, because the reticle is now something the user *operates*
and a control that disappears while you are reaching for it is not a control. Dragging the
brightness re-arms the timer, so it cannot vanish under a finger.

Exposure compensation is **snapped to the sensor's own EV grid** before anything reads it.
Android reports the range in steps (commonly ±2 EV in thirds) and rejects or silently rounds
anything off it, which would leave the sun sitting at a number the hardware is not using. The
grid is anchored at 0, not at `min`, because neutral is the one value the user must be able to
return to exactly.

**Where:** `domain/entities/exposure_range.dart`, `CameraPort.setMeteringLocked` /
`setExposureOffset`, `FocusReticle`.
**Tests:** 13 in `exposure_range_test.dart`, 12 in `camera_bloc_test.dart` (the lock and
brightness groups), 6 in `camera_chrome_test.dart`.

---

## 31. Serial uploads, and a re-check between files

**Why:** parallel uploads on a weak link starve each other and blow up memory on large files.
And a link can vanish *mid-batch* — continuing would burn an attempt on every remaining task.

**What Anchorage does:** one task at a time, with a fresh connectivity check **between**
files. Test: *"the link dropping between files parks the remainder"*.

**Where:** `ProcessUploadQueue._sweep`.

---

## 32. An in-flight guard, and the claim that the guard cannot replace

**Why:** the foreground Bloc and the WorkManager isolate both call the same engine. Without a
guard, a manual sweep racing the periodic worker uploads the same file twice.

**What Anchorage does — first half:** `ProcessUploadQueue` holds an `_inFlight` flag; a
concurrent call returns `SyncSweepReport.idle` immediately. Test: *"a second sweep started
mid-flight is a no-op"*.

**Why that is not enough:** the flag is an *object field*, and the WorkManager sweep runs in a
**separate isolate** with its own `Injector.configure()`, its own repository and its own
instance of this use case. Neither side can see the other's flag. Two sweeps could read the
same eligible row and send the same photograph twice — on a metered link, that is a real cost
to a real person.

**Second half — the claim.** A task is now taken with one conditional `UPDATE`
(`SET status='uploading' … WHERE id=? AND status IN ('queued','waitingForConnection',
'retrying')`). SQLite serialises writers, so exactly one racing sweep sees `updated == 1`; the
loser moves on without spending an attempt. A read-then-write in Dart would reintroduce the
very window it closes.

**Third half — the lease.** The mirror-image hazard is worse. A row is marked `uploading`
before its bytes move; kill the process at that instant and the row stays `uploading` forever.
`uploading` is not an eligible state, so `readEligible` never returns it again and that
photograph is *silently stranded* while the queue looks healthy. So the claim records
`claimed_at` (schema v2), `updateProgress` renews it — a 1.2 GB scan crawling over mobile data
is not a corpse — and every sweep begins by returning anything claimed more than ten minutes
ago to the queue.

Ten minutes is deliberately generous: reaping early costs a duplicate upload, reaping late
costs one extra sweep of waiting.

**Where:** `ProcessUploadQueue._inFlight`, `UploadQueueRepository.claim` /
`requeueStalled`, `UploadQueueDatabase` schema v2.
**Tests:** *"a row another sweep won in the meantime is skipped, not sent twice"*, *"a task
abandoned mid-transfer is re-queued, not stranded"*, *"a transfer that is still moving is left
alone by the reaper"*.

---

## 32a. Four reasons to sweep, not one

**Why:** "automatically retry once a stable connection is detected without user intervention"
is satisfied, on paper, by reacting to the link becoming stable. The app did exactly that,
and still had two situations where the engine sat there looking dead while the user watched:

* **New work on an already-stable link.** Tap `UPLOAD BATCH` with good Wi-Fi and nothing
  happened. The batch went to SQLite, WorkManager was asked for a wake-up — and the rows read
  `IN QUEUE` until the OS got round to it, which is minutes.
* **An elapsed backoff.** A retryable failure schedules a four-second backoff. Nothing in the
  foreground was watching the clock, so the row read `RETRYING...` and then did nothing at
  all until the 15-minute periodic sweep.

In both cases the queue was intact and the work did eventually go — the engine was *correct*.
It just looked broken, which for a resilience feature is nearly as bad.

**What Anchorage does:** a sweep now starts on five occasions — launch, the link becoming
stable, new work being queued, a backoff coming due (a `Timer` armed at the earliest
`nextAttemptAt` in the queue), and a heartbeat while work sits parked on a link that claims
to be usable. WorkManager remains the safety net for when the app is not running at all.

The last one closes a gap the first four left. "The link became stable" is a *transition*,
and there are ordinary situations that never produce one: a weak signal that reports itself
connected throughout while transfers keep collapsing, or a transport that died for a reason
the radio knows nothing about. In both the row parked correctly and then waited for an event
that had already happened. Parked work still spends no attempt — the heartbeat only makes
sure something eventually asks again, which is the difference between *waiting for a
connection* and *stuck*.

**The fix underneath:** `claim` and `requeueStalled` used to republish the queue
unconditionally, and the stale-claim reaper runs at the top of *every* sweep. "Sweep when the
queue changes" plus "always announce a change" is an infinite loop, so both now notify only
when they actually change a row — which is the correct behaviour regardless.

**Where:** `UploadManagerBloc._onQueueUpdated`, `_hasWorkReadyNow`, `_scheduleBackoffWake`.
**Tests:** *"work queued while the app is open is swept immediately"*, *"a retry is
re-attempted when its backoff elapses"*, plus two that pin the loop guards — *"an offline
link does not start a sweep that would only park"* and *"paused rows are not swept behind the
user's back"*.

---

## 33. Manual retry resets the budget

**Why:** a *human* pressing "retry" is a deliberate act with new information ("I'm on Wi-Fi
now"). Handing them the exhausted budget that produced the failure would retry once and fail
again.

**What Anchorage does:** `retry(id)` resets `attempt` to 0, clears the backoff and the
failure kind, and zeroes transferred bytes. Automatic retries keep their budget; only a human
gets a fresh one.

**Where:** `UploadQueueRepositoryImpl.retry`.

---

## 34. Pause and resume

**Why:** a user on a metered roaming connection needs a way to say "not now" that the
autonomous engine actually respects.

**What Anchorage does:** `PAUSE ALL` moves every non-terminal task to `paused`, which is *not*
eligible for pickup. Automatic sweeps triggered by the link becoming stable are suppressed
while paused — tested by *"pausing holds everything and blocks automatic sweeps"*.

**Where:** `PauseAllUploads`, `UploadManagerBloc._onSyncRequested`.

---

# Cross-cutting

## 35. A closed error taxonomy

Both apps model failure as a **sealed hierarchy** where every case maps to a *different*
remedy on screen — `AppError` in Kotlin, `Failure` in Dart. Two consequences:

1. `when` / `switch` over them is exhaustive, so a newly introduced failure mode **will not
   compile** until someone has decided how to explain it to a user.
2. Adapters translate platform exceptions at the boundary, so no `CameraException`,
   `SecurityException` or `SocketException` ever escapes the data layer. `FusedLocationTracker`
   and `CameraPluginAdapter` both carry an explicit "this class never throws" contract.

Neither app uses exceptions for control flow: `Outcome<T>` / `Result<T>` make failure *data*.

---

## 36. Injectable clocks, dispatchers, randomness and IDs

`TimeProvider`, `DispatcherProvider`, `IdGenerator`, and the `Random` inside `RetryPolicy` are
all injected ports. This is what makes the attendance window, the once-per-day rule, the
backoff schedule and the record IDs testable **deterministically**, without sleeping, without
`Thread.sleep`, and without waiting for 9 a.m.

A test asserts on `record-1`, not on a UUID wildcard.

---

## 37. Tokens transcribed, not eyeballed

The reference screenshots were extracted from the PDF and rendered at 12× zoom, then their
dominant colours **sampled programmatically**. That is why the palettes carry values like
`#2B6EEA`, `#F06363`, `#C8D2E1`, `#000514` and `#235FEB` rather than the nearest Tailwind
swatch.

Both apps then express those as **semantic roles** (`dangerArc`, `disabledContainer`,
`cameraScrim`), never raw pigment at a call site, so a re-skin is a one-file change.

---

## 38. Accessibility

* **Colour never carries state alone.** Every status has a text label —
  `OUT OF RANGE`, `WEAK SIGNAL`, `WAITING FOR CONNECTION` — so the state survives greyscale
  and colour-blindness.
* **The distance dial is one semantic node** with the description *"You are 120m from the
  office"*, because a screen reader announcing "120" and "AWAY" as unrelated nodes is
  useless.
* **The check-in button announces its gate** ("Mark attendance, locked" / "…, available").
* Camera chrome, the quick-zoom stops and the shutter all carry `Semantics` labels; the zoom
  slider is a `Semantics` slider with its current value.
* Numeric read-outs use **tabular figures** so digits do not jitter as they update.

---

## 39. Data excluded from cloud backup

Attendance records and the office anchor are **device-local proofs**. Both are excluded from
Android auto-backup and device transfer, so a restored phone cannot inherit another device's
check-in history.

**Where:** `backup_rules.xml`, `data_extraction_rules.xml`.

---

## 40. Documentation as a deliverable

The brief asks for a README. This repository ships a documentation *set*: architecture,
per-feature deep dives, a complete error-handling matrix, the design system, the testing
strategy, this improvements log, and `PROMPTS.md` recording how it was built.

The code carries the same standard. Comments explain **why**, never *what* — the rationale
for Haversine over `Location.distanceBetween`, for full jitter over plain backoff, for
`@Binds` over `@Provides`, for a hand-built zoom slider over a rotated `Slider`. A reviewer
should finish a file knowing something they could not have guessed from the code alone.

---

## 41. The dependency rule is a test, not a convention

Clean architecture usually degrades the same way: the layers are folders, folders are a
suggestion, and eighteen months later a use case imports `android.util.Log` because it was
the fastest way to debug something on a Friday.

The Android app builds from a **single Gradle module**, so the compiler can no longer refuse
that import the way a `kotlin-jvm` module used to. `ArchitectureTest` refuses it instead — it
walks the source tree and fails the build on the first violation, naming the file:

```
domain/ must not import android., androidx., com.google.android., dagger., javax.inject.
  — domain rules must stay unit-testable on the JVM with no device or stub
expected to be empty
but was: [MarkAttendanceUseCase.kt: import android.util.Log]
```

Five rules, one test each: the domain imports no framework and no outer layer, `core/common/`
inherits the same purity rule, `presentation/` never reaches into `data/`, and `data/` never
reaches into `presentation/`.

The sixth test is the one that makes the other five trustworthy. Every rule asserts *"no
violations found"*, which is exactly what a scan that silently reads zero files also reports.
So `the scan actually reaches the source tree` asserts the walk found imports at all — without
it, the whole guard would go quietly green the moment someone moved the source root.

**The honest trade:** a test can be deleted; a missing Gradle dependency cannot. This is
genuinely weaker than the module boundary it replaced. It buys one build file and one source
tree in exchange, and it fails *loudly and specifically* rather than not at all — which is the
difference between a rule and a wish.

**Where:** `app/src/test/kotlin/com/anchorage/perimeter/architecture/ArchitectureTest.kt`.

---

## 42. The flash was decorative; now it works, and it has a deadline

Three defects, one root cause: the flash rules lived inside the Bloc's toggle handler, and a
rule that lives inside a handler is a rule nobody tests. There was not a single flash test in
the suite.

**The torch was unreachable.** The cycle was a `const List` of `off → auto → always`.
`CaptureFlashMode.torch` existed, `CameraPort` accepted it, the plugin mapped it and the chrome
had an icon ready for it — but nothing a user could press ever selected it. "The flashlight
does not work" was literally true: there was no way to turn it on.

**A chosen mode was silently lost.** The flash lived on `CameraSettings`, which lives on
`CameraSession`, which is destroyed and rebuilt every time the sensor is released — a lens
switch, a phone call, a trip to another app. Set "always", tap `0.5x`, and the flash was off
again with no indication it had changed.

**A fresh controller was never told anything.** A new `CameraController` does not start where
the last one left off; the plugin's own default is `auto`. So even a user who never touched
the button had hardware set to `auto` behind a button reading "off".

The fix moves the rules into [`FlashPolicy`](../flutter/lib/domain/entities/flash_policy.dart)
and the user's choice onto `CameraState`, outside the session that keeps dying. Every open —
cold start, lens switch, resume — re-applies it explicitly, including `off`.

**The battery rule that came with it:** the torch is the only mode whose cost continues after
the user stops interacting, so it is the only one with a deadline. It never survives an
interruption (the sensor was disposed, the LED is already dark, and relighting it unattended
on resume is the most expensive thing this screen can do), and it switches itself off after
two idle minutes with a snackbar saying so. Every other mode is restored exactly as it was —
over-correcting into "reset everything on resume" would just be the original bug wearing a
hat.

**And an honest failure case.** The `camera` plugin offers no way to *ask* whether a sensor has
a flash, so assuming "front camera means no flash" would disable a working feature on the
phones that have one. Instead the mode is attempted and the platform's `setFlashModeFailed` is
translated into `FlashUnavailableFailure` — a distinct case, because "the camera could not
complete that action" invites a retry and retrying will never fit an LED to a sensor that
shipped without one. The app says "This camera has no flash", falls back to off, and leaves
the preview running.

**Where:** `flash_policy.dart`, `camera_bloc.dart`, `camera_plugin_adapter.dart`.
**Tests:** 7 in `flash_policy_test.dart`, 8 in the `flash` group of `camera_bloc_test.dart`.

---

## 43. Two platform round-trips per pinch frame, removed

`setZoom` fetched `getMinZoomLevel()` and `getMaxZoomLevel()` over the platform channel on
**every call**, to clamp against two numbers that are fixed properties of a sensor and cannot
change while it is open. A pinch fires dozens of zoom events a second, so a single gesture
spent hundreds of round-trips re-learning the same two values.

They are now read once when the controller opens and cached.

The Bloc got the matching half: a pinch held against either end of the range produces a stream
of identical clamped values, and each one used to cross the channel to set the zoom the sensor
was already at. If the value has not moved there is nothing to say, so nothing is sent.

Neither is a micro-optimisation dressed up. The preview, the sensor and the AF motor are
already the expensive part of a camera screen; adding hundreds of avoidable IPC wake-ups a
second on top of them is the difference between a viewfinder that costs what it must and one
that costs more.

**Where:** `camera_plugin_adapter.dart`, `camera_bloc.dart`.
**Test:** `a zoom that has not moved is never sent to the platform`.

---

## 44. The office is placed on a map, not grabbed blind

**What the brief asked for:** *"Button to 'Set Office Location' that fetches GPS and saves
locally."*

**What that does on a real phone:** whatever fix the device happens to produce becomes the
office — and its error is inherited by every check-in for the life of the install. A ±30 m fix
taken indoors puts the office 30 m from the building, permanently, and the user has no way to
see it or correct it. The accuracy gate ([#3](#3-a-stricter-bar-for-anchoring-than-for-checking-in))
refuses the *worst* of those, but a fix that passes the gate can still be 30 m wrong.

`OfficePickerRoute` keeps the GPS fix and demotes it from *answer* to *suggestion*. The map
opens centred on it (or on the office already saved), and the user drags the real building
under the crosshair and confirms.

### The three states of the perimeter

The 50 m ring is drawn to true scale at the current latitude and zoom, and coloured by where
the user actually is:

| State | Ring | Sentence beneath |
| --- | --- | --- |
| Inside | green | *"You are 10m from this point — inside the 50 m perimeter."* |
| Outside | red | *"You are 57m from this point — outside the 50 m perimeter."* |
| Position unknown | **neutral blue** | *"Your position is unknown, so the perimeter is shown in neutral."* |

The third state is the one worth defending. Painting the ring green or red before the device
knows where the user is would be inventing a fact, so it does neither. And the sentence is not
decoration: it is what stops the state being carried by colour alone.

### Placed by hand is recorded as placed by hand

A dropped pin has no measured accuracy. Storing `±0 m` for it would claim a precision nobody
measured, so `OfficeAnchor` carries an `AnchorSource`, and the office card reads *"Placed by
hand on the map"* instead of an accuracy it cannot justify. `PlaceOfficeAnchorUseCase` is
deliberately a sibling of `CaptureOfficeAnchorUseCase` rather than the same use case with a
flag: one gates on a measurement, the other has no measurement to gate.

### Failing without breaking

The screen adds a network dependency, so it is built to not need one:

* **Offline** — tiles fail, an amber chip and a retryable dialog appear, and the pin, the
  perimeter, the coordinates and Confirm all keep working over a plain grid. A picker that
  refuses to open without signal is useless in exactly the basements and car parks where
  people set an office.
* **Every location failure gets the dialog that fixes it** — permission denied re-opens the
  system prompt, permission blocked opens Settings, location off opens location settings, a
  timeout retries. Same rule as the Attendance banners: two cases with the same words and the
  same button are one case.
* **Nothing throws.** `OsmTileSource` translates every `IOException`, DNS failure, timeout and
  non-200 into an `AppError.MapTiles` value; a tile whose bytes will not decode is skipped and
  the grid shows through.
* **One GPS request at a time.** A jabbed "find me" cannot stack five high-accuracy requests,
  each holding the radio awake.

### The bug this found

Running it on a device caught a race the tests had not: `repeatOnLifecycle` delivers the
permission state *synchronously* while the saved-anchor read is still in flight, so the picker
would helpfully fly away from the very office the user had opened it to adjust. The first test
written asserted only the convenient ordering and passed. There is now a test for the order a
real phone produces.

**Where:** `presentation/officepicker/`, `data/map/OsmTileSource.kt`,
`domain/geo/WebMercator.kt`, `domain/usecase/PlaceOfficeAnchorUseCase.kt`.
**Tests:** 15 in `OfficePickerViewModelTest`, 9 in `WebMercatorTest`.
