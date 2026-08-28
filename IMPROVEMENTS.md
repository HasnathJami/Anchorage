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
30. [Lens pills built from the device's real cameras](#30-lens-pills-from-real-cameras)
31. [Serial uploads, and a re-check between files](#31-serial-uploads-and-a-re-check-between-files)
32. [An in-flight guard against duplicate sweeps](#32-an-in-flight-guard)
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

**What Anchorage does:** a row of chips at the bottom of the Upload Manager switches the mock
transport's behaviour at runtime. Tap **NO INTERNET**, watch rows move to
`WAITING FOR CONNECTION` with no attempt spent; tap **SERVER 503**, watch
`RETRYING... (ATTEMPT 2/5)` with jittered backoff; tap **SERVER 400**, watch it fail once and
offer a manual retry.

Nothing in the engine reads it, and swapping in the real transport makes it inert.

**Where:** `_MockBehaviourSwitcher`.

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

## 30. Lens pills from real cameras

**Why:** hard-coding `0.5 / 1 / 2` gives a single-lens budget phone three buttons, two of
which do nothing.

**What Anchorage does:** `_describeLenses` enumerates the device's actual back cameras and
builds one pill per sensor, sorted into optical order. A single-lens device gets no selector
at all rather than one pill that does nothing when tapped.

**Where:** `CameraPluginAdapter._describeLenses`, `CameraState.selectableLenses`.

---

## 31. Serial uploads, and a re-check between files

**Why:** parallel uploads on a weak link starve each other and blow up memory on large files.
And a link can vanish *mid-batch* — continuing would burn an attempt on every remaining task.

**What Anchorage does:** one task at a time, with a fresh connectivity check **between**
files. Test: *"the link dropping between files parks the remainder"*.

**Where:** `ProcessUploadQueue._sweep`.

---

## 32. An in-flight guard

**Why:** the foreground Bloc and the WorkManager isolate both call the same engine. Without a
guard, a manual sweep racing the periodic worker uploads the same file twice.

**What Anchorage does:** `ProcessUploadQueue` holds an `_inFlight` flag; a concurrent call
returns `SyncSweepReport.idle` immediately. Test: *"a second sweep started mid-flight is a
no-op"*.

**Where:** `ProcessUploadQueue._inFlight`.

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
* Camera chrome, lens pills and the shutter all carry `Semantics` labels.
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
