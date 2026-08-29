# Feature — Geo-fenced Attendance (Anchorage Perimeter)

*Task 1 of the brief. Native Android, Jetpack Compose, Kotlin Flow, Hilt.*

One screen handles both setup and check-in, as the brief requires.

---

## 1. The user journey

1. **Open the screen.** Location permission is requested. Until it is granted, an inline
   banner explains why it is needed and offers the dialog.
2. **Set Office Location.** A single high-accuracy fix is taken and, if precise enough,
   frozen as the office anchor. The card's status dot turns blue and the map thumbnail
   redraws with the saved coordinates.
3. **Watch the dial.** From then on, the distance to the anchor updates roughly twice a
   second. The ring fills red as you approach 50 m of separation and turns green inside it.
4. **Mark Attendance.** Once inside the fence, with a trustworthy fix, inside the window, and
   not already recorded today, the padlock opens and the button becomes pressable. Tapping it
   takes a *fresh* fix and re-validates every rule before writing the record.
5. **History.** The clock icon in the app bar opens the audit trail.

---

## 2. The maths

`HaversineDistanceCalculator` — great-circle distance on a spherical Earth,
`R = 6 371 008.8 m` (IUGG mean radius).

**Why implement it rather than call `Location.distanceBetween`:**

* `android.location.Location` is a framework class. Using it would drag the Android SDK into
  the domain module and force every geofence test onto an emulator or Robolectric.
* Haversine's error against Vincenty is well under 0.3 % — centimetres at the 50 m scale this
  app cares about. The trade is free.

**Implementation details that are not incidental:**

```kotlin
return 2.0 * EARTH_MEAN_RADIUS_METERS * asin(min(1.0, sqrt(h)))
```

* `asin(sqrt(h))` rather than the `atan2` form — numerically stable for the very short
  distances (metres) that dominate here, where the `atan2` form suffers cancellation.
* `min(1.0, …)` guards the one real hazard: floating-point drift pushing the argument
  fractionally above 1 turns `asin` into `NaN` for two *identical* points. There is a test
  named exactly that.

**Verified against:** identical points → exactly 0; 1° of latitude → 111 194.9 m ± 2 m;
0.00045° → 50.04 m ± 0.5 m; pole to pole → 20 015 114.4 m ± 1 m; symmetry; and the
antimeridian seam.

---

## 3. The policy

`GeofencePolicy` holds every tunable number in one reviewable place.

| Field | Default | Purpose |
| --- | --- | --- |
| `radiusMeters` | **50.0** | The brief's requirement |
| `exitHysteresisMeters` | 8.0 | Anti-strobe band |
| `maxTrustedAccuracyMeters` | 50f | A fix wider than the fence tells you nothing |
| `maxAnchorAccuracyMeters` | 35f | Stricter bar for *saving* an office |

### Hysteresis — a Schmitt trigger for GPS

A user standing still on the boundary produces readings that jitter by several metres a
second. With a bare `distance < 50` the button strobes, and can be disabled between the user
deciding to tap it and their finger landing.

```
                 INSIDE  ←────────── enter at ≤ 50 m ──────────
                    │
                    └──────────────► exit at > 58 m ──────────► OUTSIDE
```

The previous status is threaded through the Flow with `scan`, so the evaluator stays a pure
function with no mutable state.

> **The gate does not get hysteresis.** `MarkAttendanceUseCase` evaluates with
> `previousStatus = null`, i.e. against the true 50 m. A forgiving *indicator* is good UX; a
> forgiving *gate* is a false attendance record. Test:
> `hysteresis is not applied to the authoritative decision`.

### Accuracy as a first-class concept

`GeofenceReading` carries `isConfident` **separately** from `status`:

| Distance | Accuracy | `status` | `isConfident` | UI |
| --- | --- | --- | --- | --- |
| 12 m | ± 6 m | INSIDE | true | Green, check-in unlocked |
| 12 m | ± 90 m | INSIDE | **false** | Amber `WEAK SIGNAL`, locked |
| 120 m | ± 6 m | OUTSIDE | true | Red `OUT OF RANGE`, locked |

A fix reporting *no* accuracy is treated as `Float.MAX_VALUE` — maximally untrustworthy.
Failing closed is the only safe default for a value that gates a check-in.

### The attendance window

**The shipped default is currently the whole day** (`12:00 AM - 11:59 PM`), widened so the
app can be tried and screenshotted at any hour; the two constants in `AttendanceWindow` are
the only thing that changes, and the rule below is otherwise untouched.

The reference design prints `AVAILABLE 09:00 AM - 10:30 AM`. `AttendanceWindow` makes that a
real, enforced rule. Both ends are inclusive, because "closes at 10:30" reads to a human as
"10:30 still works".

---

## 4. The domain model

```
GeoPoint            latitude/longitude, validated in the constructor
LocationFix         point + accuracyMeters + timestamp + isMock
OfficeAnchor        point + the accuracy and time of the fix it came from
AttendanceRecord    id, time, point, distance, accuracy, anchor label
GeofenceReading     distance, radius, status, accuracy, isConfident, isMockProvider
AttendanceStatus    anchor + reading + today's record + window → canMarkAttendance
```

`GeoPoint` validates in its `init` block, so an invalid coordinate cannot exist anywhere in
the system and no downstream calculation has to defend against one.

`AttendanceStatus.canMarkAttendance` is the single expression of every gate, in the same
order the use case enforces them:

```kotlin
isOfficeConfigured && !isAlreadyMarkedToday && isWindowOpen && reading?.allowsCheckIn == true
```

Because the button's enabled state and the use case's decision read from the same rule, they
cannot drift.

---

## 5. Use cases

| Use case | Responsibility |
| --- | --- |
| `CaptureOfficeAnchorUseCase` | One high-accuracy fix → accuracy gate → persist |
| `ObserveAttendanceStatusUseCase` | Fuse anchor + position stream + history into one `Flow` |
| `MarkAttendanceUseCase` | The authoritative decision |
| `ClearOfficeAnchorUseCase` | Forget the anchor |
| `ObserveAttendanceHistoryUseCase` | Newest-first log |

### `ObserveAttendanceStatusUseCase` — three details

1. **The position stream is prefixed with `null` via `onStart`.** `combine` will not emit
   until *every* source has produced a value; without this the whole screen stays blank until
   the first GPS fix, which on a cold start can be twenty seconds. With it, the office card
   and any permission banner render immediately.
2. **`scan` threads the previous `ProximityStatus`** into the evaluator. That is what powers
   the hysteresis; a stateless `map` could not.
3. **"Today" is recomputed on every emission**, not captured at subscribe time, so a session
   left open across midnight re-arms instead of reporting yesterday's check-in.

A transient location error does **not** erase the last known reading — the user still sees how
far they were, alongside the banner explaining why it stopped updating.

### `MarkAttendanceUseCase` — the ordering

```
1. window closed?          → reject  (no GPS call)
2. no anchor?              → reject  (no GPS call)
3. already marked today?   → reject  (no GPS call)
4. take a FRESH fix        ← the only expensive step
5. accuracy insufficient?  → reject
6. outside the radius?     → reject, with the distance attached
7. append the record
```

Cheap, certain rejections run first so a user tapping at 4 p.m. is told why instantly instead
of watching a spinner for fifteen seconds.

---

## 6. The data layer

### `FusedLocationTracker`

The app's entire blast radius for positioning failures. Contract: **it never throws.**

Preflight, in order:

1. permission not granted → `PermissionDenied`
2. device location toggle off → `ServicesDisabled`

(Permission is checked first deliberately: if both are broken, telling someone to turn on
location does not help them.)

Then:

| Situation | Result |
| --- | --- |
| `SecurityException` mid-stream (permission revoked live) | `PermissionDenied` |
| `LocationAvailability.isLocationAvailable == false` | `PositionUnavailable` |
| No fix inside the deadline | `Timeout(waitedMillis)` |
| Anything else | `PositionUnavailable` |

Failures are delivered **as values on the stream**, never thrown. A `Flow` that throws tears
down the collector and loses the hysteresis state built up above it.

### `OfficeAnchorLocalSource` (DataStore)

* Read as a stream, so the screen reacts the instant a new office is captured.
* The corrupt-file `IOException` DataStore raises *inside* the flow is caught and converted to
  `AppError.Storage`; unhandled it would propagate to the UI collector and kill the screen.
* A **partially written** anchor reads as *no anchor*, never as a coordinate with zeroes
  standing in for the missing half.
* An out-of-range persisted coordinate degrades to "not configured" rather than throwing.

### `AttendanceRepositoryImpl` (Room)

* Denormalises the **local** calendar date into a unique-indexed column. That index — not
  application code — is what makes once-per-day true under a race.
* `SQLiteConstraintException` → `AppError.Attendance.AlreadyMarked`, carrying the *existing*
  record's timestamp.
* Read flows `catch` into an empty list: a corrupt history degrades the history sheet, it does
  not take down the attendance screen collecting it.

---

## 7. The screen, state by state

| State | Dial | Pill | Panel | Helper text |
| --- | --- | --- | --- | --- |
| No office | `--` / `NO OFFICE` | `OFFICE NOT SET` (red) | Locked padlock | "Anchor your office above to start measuring distance." |
| Awaiting fix | `--` / `LOCATING` | `AWAITING FIX` (blue) | Locked | "Acquiring a satellite fix…" |
| Out of range | `120m` / `AWAY`, red arc | `OUT OF RANGE` (red) | Locked | "Move within 50 meters of the designated office location to enable check-in." |
| Weak signal | last distance, grey arc | `WEAK SIGNAL` (amber) | Locked | "The signal is accurate to about ±90 m, which is wider than the 50 m perimeter…" |
| In range | `12m` / `AWAY`, green arc | `IN RANGE` (green) | **Open padlock, button enabled** | "You are inside the office perimeter. Check-in is unlocked." |
| Marked today | green arc | `CHECKED IN` (green) | Check icon, "Attendance Marked" | "Attendance recorded at 09:12 AM, 12m from the office." |
| Window closed | unchanged | unchanged | Locked | caption flips to `WINDOW CLOSED · 09:00 AM - 10:30 AM` in amber |

The dial, the pill and the padlock all read from the same `ProximityUi` value, so a green ring
above a red pill is impossible by construction.

---

## 8. Error handling

Every failure maps to a banner with a remedy. Full matrix in
[ERROR-HANDLING.md](ERROR-HANDLING.md).

| Condition | Banner | Action |
| --- | --- | --- |
| Permission not yet granted | "Location permission needed" | **Grant permission** |
| Permission permanently denied | "Permission is blocked" | **Open settings** |
| Device location off | "Location is switched off" | **Turn on location** |
| Fix too coarse to anchor | "Fix too coarse to anchor" (with both numbers) | **Try again** |
| No position available | "No position available" | **Retry** |
| Storage unreadable | "Saved data could not be read" | **Retry** |
| Mock provider active | "Mock location detected" | **Dismiss** (does **not** block) |

Momentary rejections — out of range at tap time, window closed, already marked — get a
Snackbar instead, because they are events rather than states.

---

## 9. Tests

96 Android unit tests, of which the geofence-specific ones are:

| File | Covers |
| --- | --- |
| `HaversineDistanceCalculatorTest` | 7 tests — reference distances, symmetry, NaN guard, antimeridian, poles |
| `GeoPointTest` | 5 — constructor validation including boundaries and NaN |
| `GeofenceEvaluatorTest` | 10 — inside/outside/boundary, both hysteresis directions, confidence, progress clamping, anchor gate |
| `AttendanceWindowTest` | 6 — inclusive ends, one minute early, one second late, inverted window |
| `CaptureOfficeAnchorUseCaseTest` | 5 — persist, accuracy rejection, error propagation, storage failure, boundary |
| `MarkAttendanceUseCaseTest` | 9 — every rejection path, ordering (no GPS call on cheap rejections), hysteresis exclusion |
| `ObserveAttendanceStatusUseCaseTest` | 6 — immediate emission, hysteresis across emissions, error tolerance, window |
| `AttendanceViewModelTest` | 18 — permission escalation, projection, actions, concurrency guard |
| `AttendanceFormattersTest` | 7 — distance, accuracy, coordinates, timezone-correct clock and date |
| `AttendanceRepositoryImplTest` | 6 — local-date derivation across the UTC boundary, unique-index violation |
| `OfficeAnchorLocalSourceTest` | 6 — round-trip, clear, partial write, out-of-range value, default label |
| `FusedLocationTrackerTest` | 5 — preflight gates and their ordering |

```bash
cd android && ./gradlew test
```
