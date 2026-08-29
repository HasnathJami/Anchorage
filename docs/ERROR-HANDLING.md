# Error Handling

> **Brief:** *"Error Handling: Graceful handling of permissions and hardware failures."*

This document is the complete matrix: every failure mode both apps can experience, how it is
detected, and exactly what the user sees.

---

## 1. The principles

**1. Failure is data, not an exception.** `Outcome<T>` (Kotlin) and `Result<T>` (Dart) over
closed sealed hierarchies. No `try/catch` for control flow anywhere above the data layer.

**2. Adapters never throw.** `FusedLocationTracker`, `CameraPluginAdapter`,
`UploadQueueRepositoryImpl`, `OfficeAnchorLocalSource`, `AttendanceRepositoryImpl` and
`MockUploadApi` all carry an explicit "this class never throws" contract. Platform exceptions
are translated at the boundary and never escape.

**3. Every case maps to a different remedy.** If two failures would show the same message and
the same button, they should be one case. This is why `PermissionDenied` and
`PermissionPermanentlyDenied` are separate types, and why `NoConnectionFailure` and
`LowBandwidthFailure` are.

**4. Exhaustiveness is enforced by the compiler.** Adding a case to the sealed hierarchy
breaks the `when`/`switch` in the presentation layer until someone decides what the user
sees.

**5. Persistent states get banners; momentary events get toasts.** A missing permission is
a *state* — a toast that vanishes in a couple of seconds leaves a screen that looks
inexplicably inert. Being out of range at the instant you tapped is an *event*.

On the camera the toast is `HarborToast`, at the **top** of the screen rather than the
bottom, because the bottom edge is the shutter and a confirmation of the shot just taken
must not cover the control the user is about to press again. A confirmation dwells for
`HarborToast.brief` (2.5 s); anything the user has to read and act on gets
`HarborToast.standard` (4 s).

**6. A message without a remedy is half an answer.** Every banner carries an action.

**7. Fail closed on anything that gates a decision.** A fix reporting no accuracy is treated
as maximally untrustworthy, not as perfect.

---

## 2. Anchorage Perimeter — the taxonomy

```
AppError
├── Location
│   ├── PermissionDenied
│   ├── PermissionPermanentlyDenied
│   ├── ServicesDisabled
│   ├── PositionUnavailable
│   ├── Timeout(waitedMillis)
│   └── InsufficientAccuracy(reported, required)
├── Storage
│   ├── ReadFailed
│   ├── WriteFailed
│   └── Corrupted(detail)
├── Attendance
│   ├── OfficeNotConfigured
│   ├── OutsideGeofence(distance, radius)
│   ├── WindowClosed
│   └── AlreadyMarked(markedAtEpochMillis)
└── Unexpected(detail)
```

### What the user sees

| Failure | Surface | Title / message | Action |
| --- | --- | --- | --- |
| `Location.PermissionDenied` | Banner (blue) | **Location permission needed** — "Anchorage needs your location to tell whether you are at the office. It is only read while this screen is open." | **Grant permission** → system dialog |
| `Location.PermissionPermanentlyDenied` | Banner (red) | **Permission is blocked** — "Android will not ask again. Enable location for Anchorage in system settings to continue." | **Open settings** → app settings |
| `Location.ServicesDisabled` | Banner (amber) | **Location is switched off** — "Turn on device location so Anchorage can measure your distance from the office." | **Turn on location** → location settings |
| `Location.PositionUnavailable` | Banner (amber) | **No position available** — "The device could not produce a location fix. This usually clears up outdoors." | **Retry** → restart the stream |
| `Location.InsufficientAccuracy` | Banner (amber) | **Fix too coarse to anchor** — "The reading was accurate to ±120 m but anchoring an office needs ±35 m or better, otherwise the 50 m perimeter would be meaningless." | **Try again** → re-capture |
| `Storage.*` | Banner (red) | **Saved data could not be read** — "Anchorage could not reach its local store. Your office and history may be out of date." | **Retry** |
| Mock provider active | Banner (amber) | **Mock location detected** — "This device is reporting a simulated position. The check-in will still work and is recorded as such." | **Dismiss** |
| `Location.Timeout` | Snackbar | "Could not get a fix in time. Try again with a clearer view of the sky." | — |
| `Attendance.OutsideGeofence` | Snackbar | "You moved out of range before the check-in completed." | — |
| `Attendance.WindowClosed` | Snackbar | "Check-in is only open 09:00 AM - 10:30 AM." | — |
| `Attendance.AlreadyMarked` | Snackbar | "Attendance for today is already recorded." | — |
| `Attendance.OfficeNotConfigured` | Snackbar | "Anchor your office location first." | — |
| `Unexpected` | Snackbar | "Something went wrong. Please try again." | — |

### Permission: three states, not two

`RequestMultiplePermissions` returns the same `false` for "denied once" and "blocked
forever". They are completely different situations, and repeatedly offering the system dialog
to someone whose OS will never show it again is a dead end.

Anchorage reads `shouldShowRequestPermissionRationale` **after** the dialog closes to tell
them apart. The flag lives on `Activity`, so the helper walks the `ContextWrapper` chain
rather than assuming the composition's context is one — it is not, when hosted in a
`ComposeView`.

Permission state is also re-checked on **every resume**, via `repeatOnLifecycle(RESUMED)`.
That is what makes the screen recover silently when the user grants permission in Settings and
swipes back.

### Notice ownership

A real bug, caught by a failing test: the "fix too coarse" banner appeared and was wiped by
the very next GPS update, a fraction of a second later.

The rule now:

```kotlin
notice = if (notice.isOwnedByUserAction()) notice else streamNotice
```

The ambient location stream owns ambient notices and may clear them freely; it may **never**
overwrite one raised by the permission flow or by an explicit user action.

### Data-layer robustness

| Situation | Handling |
| --- | --- |
| DataStore file corrupt | `IOException` caught *inside* the flow → `Storage.ReadFailed`. Unhandled it would propagate to the UI collector and kill the screen. |
| Anchor partially written (process death mid-save) | Reads as **no anchor**, never as a coordinate with zeroes for the missing half |
| Persisted coordinate out of range | Degrades to "not configured" rather than throwing |
| Room history unreadable | `catch` → empty list. A corrupt history degrades the history sheet; it does not take down the attendance screen. |
| Duplicate insert | Unique-index violation → `Attendance.AlreadyMarked` carrying the **existing** record's timestamp |
| Permission revoked mid-stream | `SecurityException` → `PermissionDenied` delivered as a value on the stream |
| Fix with no accuracy claim | `Float.MAX_VALUE` — maximally untrustworthy, fails closed |

---

## 3. Anchorage Harbor — the taxonomy

```
Failure
├── PermissionDeniedFailure(permission)
├── PermissionPermanentlyDeniedFailure(permission)
├── PermissionRestrictedFailure(permission)
├── CameraUnavailableFailure
├── CameraOperationFailure(operation)
├── CameraInterruptedFailure
├── StorageWriteFailure
├── StorageReadFailure
├── MissingArtifactFailure(path)
├── NoConnectionFailure
├── LowBandwidthFailure(observedBytesPerSecond?)
├── TimeoutFailure
├── ServerFailure(statusCode, isRetryable)
└── UnexpectedFailure(detail?)
```

Two derived predicates drive the entire sync engine:

```dart
bool get isRetryable            // could another attempt plausibly succeed?
bool get isConnectivityRelated  // is the only thing missing a network?
```

`isConnectivityRelated` is what makes "no internet" a pause rather than a spent attempt.

### Camera failures

| Situation | Failure | Phase | What the user sees |
| --- | --- | --- | --- |
| Permission not granted | `PermissionDeniedFailure` | `permissionRequired` | Full-screen: **Camera access needed** → **ALLOW CAMERA** |
| Permanently denied / MDM | `PermissionPermanentlyDenied` / `Restricted` | `permissionBlocked` | **Camera access is blocked** → **OPEN SETTINGS** |
| No camera on device | `CameraUnavailableFailure` | `unavailable` | **No camera available** → **OPEN UPLOAD MANAGER** |
| Sensor taken away | `CameraInterruptedFailure` | `idle` | **Preview paused** → **REOPEN CAMERA** |
| Disk full on save | `StorageWriteFailure` | ready | Snackbar: "Could not write to local storage. Free some space and try again." |
| Any other plugin error | `CameraOperationFailure(op)` | ready | Snackbar: "The camera could not complete that action." |

Every blocking state offers an action. `unavailable` deliberately routes to the Upload
Manager: a device with no camera can still review and upload what it already has.

### Upload failures

| Failure | Retryable | Consumes an attempt | Row status | Row shows |
| --- | --- | --- | --- | --- |
| `NoConnectionFailure` | yes | **no** | `waitingForConnection` | `WAITING FOR CONNECTION` (amber) |
| `LowBandwidthFailure` | yes | **no** | `waitingForConnection` | `WAITING FOR CONNECTION` (amber) |
| `TimeoutFailure` | yes | yes | `retrying` | `RETRYING... (ATTEMPT 2/5)` (red) |
| `ServerFailure(503)` | yes | yes | `retrying` | `RETRYING... (ATTEMPT 2/5)` (red) |
| `ServerFailure(400)` | **no** | yes | `failed` | `REJECTED BY SERVER` + retry/discard |
| `MissingArtifactFailure` | **no** | yes | `failed` | `FILE NO LONGER ON DEVICE` + retry/discard |
| Budget exhausted | — | — | `failed` | `FAILED` + retry/discard |
| `StorageReadFailure` on the queue | — | — | — | Sweep returns a failure; the queue is untouched |

A failed row is never silently dropped. It stays visible with a **retry** and a **discard**
control, and manual retry resets the attempt budget — a human pressing retry has new
information ("I'm on Wi-Fi now") and deserves a fresh budget.

### Background isolate

| Hazard | Handling |
| --- | --- |
| Isolate starts with no plugins/DI | `WidgetsFlutterBinding.ensureInitialized()` + fresh `Injector.configure()` |
| Accidental wake-up loop | Scheduling disabled inside the isolate; intent expressed via the return value |
| Exception escaping to the OS | Everything wrapped; an escaped throw is reported as a crash and can get background execution throttled |
| Lying to the OS about success | Returns `!shouldReschedule` for the one-shot; `true` only for the periodic task |
| WorkManager unavailable (OEM, work profile) | `main()` catches it, logs, and the app runs with foreground-only sync |

---

## 4. Crash-safety checklist

Concrete "this would have crashed" cases that are handled:

**Anchorage Perimeter**

- [x] `SecurityException` from a permission revoked while the stream is live
- [x] Corrupt or unreadable DataStore file
- [x] Partially written anchor after process death mid-save
- [x] Out-of-range coordinate persisted by an older build
- [x] Division by zero in dial progress when the radius is degenerate (guarded by
      `require(radiusMeters > 0)`)
- [x] `NaN` from `asin` for two identical points (guarded by `min(1.0, …)`)
- [x] Room unique-constraint violation on a duplicate check-in
- [x] Play Services returning `null` for `getCurrentLocation`
- [x] Location toggle switched off between preflight and the call
- [x] Day rollover while the screen is open

**Anchorage Harbor**

- [x] Camera reclaimed by the OS during a call → sensor released, preview rebuilt on resume
- [x] Permission revoked from Settings while backgrounded → re-checked on resume
- [x] Two controllers open at once → previous disposed before opening
- [x] Out-of-range zoom from a pinch → clamped in the adapter
- [x] Double-tapped shutter → `droppable()` transformer + `isTakingPicture` guard
- [x] `Image.file` for a deleted capture → `errorBuilder` placeholder, not a red screen
- [x] Zero-byte file → progress returns 0 rather than dividing by zero
- [x] Empty queue → `BatchProgress.fraction` returns 0, not `NaN`
- [x] Unknown enum name from a newer build → degrades to a safe default rather than throwing
- [x] Duplicate sweep from the Bloc and the worker → `_inFlight` guard
- [x] Half-enqueued batch after a crash → single transaction
- [x] Cache directory cleared by the OS → files copied to app-private storage at capture time
