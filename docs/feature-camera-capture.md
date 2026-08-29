# Feature — Advanced Camera & Batch Capture (Anchorage Harbor)

*Task 2 of the brief, first half. Flutter, BLoC, the `camera` plugin.*

> **Brief:** *"Build a camera preview screen `CameraPreviewScreen`. Zoom: implement
> pinch-to-zoom, a slider and rounded buttons (0.5x, 1x, …available back cameras). Manual
> Focus: tap-to-focus functionality with a visual indicator at the tap point. Batch
> Management: capture multiple batches of images. Show a list of 'Pending Uploads.'"*

---

## 1. The screen

A direct transcription of the reference design.

```
┌──────────────────────────────────────────┐
│ (✕)                          ⚡    ⚙      │   close · flash · settings sheet
│              BATCH CAPTURE               │   or "BATCH · 12 CAPTURED"
│                                          │
│                                    ┌──┐  │
│                                    │8x│  │   vertical zoom slider
│           [ live preview ]         │▓ │  │   (labels inside the track)
│                                    │● │  │
│                                    │1x│  │
│                                    └──┘  │
│              (0.5) (1x) (2)              │   quick-zoom stops — from the
│                                          │   sensor's real zoom range
│   ┌──┐(12)        ◯◯◯          (⟳)      │   thumbnail · shutter · flip
│   └──┘                                   │
│                                          │
│   [   ⚓  UPLOAD BATCH (12)          ]   │
└──────────────────────────────────────────┘
```

The reference render carries the words `VISUAL` and `LIVE VIEW` in those two caption slots.
They are artefacts of how the reference image was produced, not labels with meaning, and
transcribing them literally produced a camera that announced "LIVE VIEW" across its own
shutter button. The slots are kept — the layout is the reference's — and filled with the one
fact about this camera that differs from every other camera the user has held: this frame is
joining a batch, and here is how large that batch is.

Chrome is translucent rather than solid, so the frame being composed stays visible
underneath — a solid button on a camera hides exactly the part of the shot it sits on.

---

## 2. Zoom — three input paths, one model

| Input | Event | Behaviour |
| --- | --- | --- |
| Pinch | `CameraPinchStarted` → `CameraPinchZoomed(scale)` | `baseZoom × scale` |
| Slider | `CameraZoomChanged(absolute)` | Absolute |
| Quick-zoom stop | `CameraZoomStopSelected(stop)` | Absolute; opens another rear camera first, but only if this one cannot reach the ratio |

### Pinch is anchored to the gesture's origin

`ScaleUpdateDetails.scale` is **cumulative for the gesture**. Multiplying it by the *current*
zoom on every frame compounds, and the preview rockets to maximum from the smallest pinch.

`CameraPinchStarted` records the zoom the gesture began at; each update computes
`_pinchBaseZoom × scale`. There is a test that sends the same scale twice within one gesture
and asserts the zoom did not move the second time.

Single-finger pans (`pointerCount < 2`) are ignored, so tap-to-focus never nudges the zoom.

### Clamping lives in the adapter

The platform **throws** on an out-of-range zoom, and a pinch gesture will absolutely produce
one. `CameraPluginAdapter.setZoom` clamps against the live min/max before calling through.
The Bloc also clamps for the optimistic UI update, so the slider tracks the finger rather than
the platform channel.

### The slider is hand-built

A `RotatedBox`-wrapped Material `Slider` inverts its own gesture axis — dragging *up*
decreases the value — and cannot place labels inside the track the way the reference does.
`VerticalZoomSlider` is ~90 lines of `GestureDetector` + `LayoutBuilder`, and behaves.

### The quick-zoom stops are ratios, not cameras

This is the part that was wrong, and it is worth writing down properly because the wrong
version is the obvious one.

The first implementation built the `0.5 / 1 / 2` row from the physical back cameras
`availableCameras()` reports, and rendered nothing when there were fewer than two of them —
on the reasonable theory that a lone pill which does nothing when tapped is worse than no
row. Both halves of that reasoning are sound. The premise is not.

`availableCameras()` reports **logical** cameras. A phone with an ultra-wide, a main and a
telephoto typically publishes *one* rear camera whose zoom range spans all three, and lets
the platform switch the physical sensor underneath as the zoom crosses a threshold. So the
count was almost always one, the row collapsed, and the reference design's most recognisable
control was empty space on nearly every device — including the emulator a reviewer would
reach for first.

`ZoomLadder.forRange(minZoom:maxZoom:)` builds the row from the sensor's zoom range instead:

* **1x is always present.** It is the frame the user is looking at. A camera whose current
  framing has no button is disorienting, even on hardware that cannot zoom at all.
* **A wide button is earned, not assumed.** It appears only when the reported minimum is
  genuinely below 1x (`ultraWideBelow = 0.95`, because devices report 0.5, 0.6 and
  0.5999999 for the same physical lens), and it targets that exact minimum. A 0.6x
  ultra-wide is honestly labelled `0.6` and the tap lands where the hardware stops instead
  of being silently clamped.
* **2x, 3x, 5x, 10x** are offered only up to what the sensor reaches, capped at three
  buttons — the reference's width, and about as many round targets as a thumb can hit
  one-handed while the other hand holds the subject.
* **A garbled range degrades to a bare 1x** rather than to a row of buttons the driver
  would refuse.

`ZoomStopSelector` then does one thing the old pills did not: when the live zoom sits
*between* stops, the selected button shows the live value (`1.7x`) instead of its own label.
That is what the platform camera apps do, and it turns the row from three buttons that lie
between stops into an always-correct read-out.

**Physical lens switching still exists** for the minority of devices that publish each rear
sensor separately. `CameraZoomStopSelected` checks whether the open sensor can reach the
requested ratio; only when it cannot does it look for the rear camera whose native factor is
closest, open that, and then set the zoom. The front camera is never a candidate — it is
reached from the flip button, matching the reference.

`CameraPluginAdapter` also **opens at 1x rather than at the sensor's minimum**. On a phone
whose logical rear camera spans an ultra-wide, the minimum is 0.5, and starting there meant
the app opened on a distorted wide-angle frame nobody had asked for.

---

## 3. Tap-to-focus

`CameraFocusRequested(x, y)` carries **normalised** preview coordinates (0–1 on both axes), so
the domain never has to know the preview's pixel size or rotation. Out-of-bounds values are
clamped rather than passed to the platform.

The adapter sets **focus and exposure together**. Tapping a dark corner and getting a sharp
but unreadable frame is not what the gesture means to a user.

The reticle is shown **optimistically**, before the platform confirms — a focus indicator that
waits for the hardware feels broken even when it works. It is cleared by a dwell timer that
carries the requesting timestamp, so a newer tap keeps its own indicator instead of being
cancelled by the older one's expiry.

Visually it is a yellow square that snaps in and settles (`Curves.easeOutBack`), mirroring the
platform camera apps the user already knows.

---

## 3a. Flash — and why it needs a policy object

The flash button cycles **off → auto → always → torch**, and the order is not arbitrary: the
torch is the only mode whose cost continues after the user stops interacting, so it sits one
press before off rather than somewhere a thumb lands on the way past.

All of it lives in `FlashPolicy`, in the domain, because the previous version lived in the
Bloc's toggle handler as a `const List` and carried three defects nobody could see:

| Defect | Cause | Symptom |
| --- | --- | --- |
| The torch was unreachable | The cycle stopped at `always` | "The flashlight doesn't work" — there was no way to switch it on |
| A chosen mode reverted to off | Flash lived on `CameraSettings`, which lives on the session, which is destroyed on every lens switch and pause | Set "always", tap `0.5x`, flash is off again with no indication |
| A fresh controller was never told | A new `CameraController` defaults to `auto`, not to the last one's mode | Hardware firing a flash behind a button reading "off" |

The fix is one sentence: **the flash is a user preference, not a session property.** It lives
on `CameraState`, survives every controller that dies under it, and is re-applied explicitly
after every open — including when the chosen mode is `off`, because "off" is a value the
hardware has to be told.

### The battery rules

The torch is the largest continuous draw this screen can create — on most phones larger than
the sensor and the preview combined. Two rules follow, both in `FlashPolicy`:

* **It never survives an interruption.** Pausing disposes the controller, so the LED is
  already dark; recording that in the state is what stops it coming back lit on resume. Every
  *other* mode is restored exactly as it was — over-correcting into "reset everything" would
  just be the reverting-flash bug wearing a hat.
* **It has a deadline.** Two idle minutes and the torch switches itself off, announced in a
  snackbar rather than done silently: a light going out on its own is confusing unless the app
  says it was deliberate. The deadline is a cancellable `Timer`, not an awaited delay — the
  flash handler is `sequential`, so awaiting a two-minute timeout inside it would stall every
  other sequential event behind it.

### Sensors with no flash

The `camera` plugin offers no way to *ask* whether a sensor has an LED, and assuming "front
camera means no flash" would disable a working feature on the phones that have one. So the
mode is attempted, and the platform's `setFlashModeFailed` is translated into
`FlashUnavailableFailure` — a case of its own, because "the camera could not complete that
action" invites a retry, and no amount of retrying will fit an LED to a sensor that shipped
without one. The app says *"This camera has no flash"*, falls back to off, and leaves the
preview running.

---

## 4. Lifecycle — the bug this feature is really about

Android hands the camera to whichever app asked most recently. An app that holds the sensor
while backgrounded leaves the user staring at a **frozen black rectangle** after a phone call.
This is the single most common defect in Flutter camera apps.

`CameraPreviewPage` is a `WidgetsBindingObserver`:

| Lifecycle | Event | Action |
| --- | --- | --- |
| `inactive` / `paused` / `hidden` / `detached` | `CameraPaused` | Dispose the controller, clear the session |
| `resumed` | `CameraResumed` | Re-check permission, then re-open |

`CameraSession.previewKey` increments on every open. The widget tree keys the preview on it,
so a re-opened controller produces a **new** platform view rather than reusing a disposed
texture.

Resume re-checks permission because it can have been revoked from Settings while the app was
away — a test asserts exactly that.

`_open` also disposes the previous controller **first**. Holding two controllers open is the
fastest route to a "camera in use" error on mid-range Android hardware.

---

## 5. Capture and batching

```
shutter → adapter.takePicture() → copy into app-private storage
        → CapturedShot → CaptureBatch.add()
```

**Files leave the cache immediately.** The `camera` plugin writes to the app's *cache*
directory, which the OS may clear at any moment under storage pressure. Every capture is
copied into `documents/captures/` and the cache copy deleted, before the shot ever reaches the
batch. A queued upload must still find its bytes tomorrow morning.

`CapturedShot` records the lens label and zoom level alongside the file, for the audit trail
and for debugging "why is this frame wider than the others?".

**A batch is handed over, never shared.** `CameraBatchSubmitted` enqueues every shot and
starts a **fresh** batch, so the sync engine and the camera can never mutate the same list.
The corner thumbnail shows the newest shot with a blue count badge, exactly as in the
reference.

### The batch review sheet

Tapping the thumbnail opens `BatchReviewSheet`: a grid of the shots that have **not** been
handed over, where tapping one drops it.

That moment is the whole point. A field operator photographs a site with no signal, ends up
with fourteen frames, and knows two of them are blurred. Once a batch reaches the queue those
two are *durable* — retried across reboots, eventually costing real bandwidth on a metered
link. Dropping them a second earlier costs nothing. `CameraShotDiscarded` had been modelled
since the first version of this Bloc and was reachable from no UI at all; this is the screen
it was waiting for.

Discarding deletes the file, not just the list entry. The photograph is on disk the instant
the shutter fires — that ordering is the app's durability story — so a discard that only
forgot the entry would leave every rejected frame on the device for good. `CameraPort.discard`
returns nothing, deliberately: a file that is already gone is the outcome the caller wanted,
and there is no remedy to offer for an unlink that fails.

The sheet is a modal route, which makes it a *sibling* of the camera page in the navigator
rather than a descendant — `context.read<CameraBloc>()` inside it would throw. The Bloc is
handed over explicitly with `BlocProvider.value`, which is also what keeps the grid live: the
first version passed a snapshot of the batch, and a discarded frame stayed on screen.

---

## 6. Declared concurrency

Flutter's default event transformer is `concurrent()` — for a shutter button that means a user
hammering it queues twelve captures.

| Event | Transformer | Why |
| --- | --- | --- |
| `CameraShutterPressed` | `droppable()` | One photograph per **completed** capture |
| `CameraZoomChanged`, `CameraPinchZoomed`, `CameraFocusRequested` | `restartable()` | Only the newest value matters; a pinch emits dozens per second |
| `CameraBatchSubmitted` | `droppable()` | A double tap must not enqueue twice |
| Everything else | `sequential()` | Lifecycle and lens changes must not interleave |

The adapter adds a second guard: `controller.value.isTakingPicture` returns a benign
`CameraOperationFailure('capture-in-progress')` rather than throwing.

---

## 7. Error handling

`CameraPluginAdapter` **never throws**. Every `CameraException` is translated at the boundary:

| Plugin code | Failure | Phase | What the user sees |
| --- | --- | --- | --- |
| `CameraAccessDenied` | `PermissionDeniedFailure` | `permissionRequired` | "Camera access needed" → **ALLOW CAMERA** |
| `CameraAccessDeniedWithoutPrompt` | `PermissionDeniedFailure` | `permissionRequired` | as above |
| `CameraAccessRestricted` | `PermissionRestrictedFailure` | `permissionBlocked` | "Camera access is blocked" → **OPEN SETTINGS** |
| `cameraNotFound` / empty list | `CameraUnavailableFailure` | `unavailable` | "No camera available" → **OPEN UPLOAD MANAGER** |
| controller gone mid-operation | `CameraInterruptedFailure` | `idle` | "Preview paused" → **REOPEN CAMERA** |
| `FileSystemException` on save | `StorageWriteFailure` | stays ready | Snackbar: free some space |
| anything else | `CameraOperationFailure(op)` | stays ready | Snackbar |

Every blocking state **offers an action**. A camera screen that only says "permission denied"
leaves the user stuck. Note that `unavailable` routes to the Upload Manager — a device with no
camera can still review and upload what it already has.

Before the sensor opens, and in tests and previews where no camera exists, the frame shows a
gradient in the reference design's own tones rather than a black void that reads as a crash.

---

## 8. Why the camera sits behind a port

`CameraController` cannot be constructed on the Dart VM. A Bloc that touched the plugin
directly could only be tested on a physical device — which in practice means it would not be
tested.

`CameraPort` is the seam. `FakeCamera` implements it in ~60 lines, and every capture rule —
zoom clamping, pinch anchoring, lens switching, batching, lifecycle, error mapping — is
covered by `flutter test` runs that finish in under a second.

The one pragmatic concession: `_PreviewSurface` reads the concrete `CameraPluginAdapter` from
the service locator to obtain the live `CameraController` for `CameraPreview`. There is no way
to render a platform texture through an abstraction, and pretending otherwise would be
ceremony. The *logic* stays behind the port; only the pixels reach through.

---

## 9. Tests

`camera_bloc_test.dart` — 32 tests:

| Group | Covers |
| --- | --- |
| startup and permissions | already granted; ask then open; soft denial stays askable; permanent denial switches remedy to Settings; no camera degrades |
| lifecycle | sensor released on background; re-opened on resume; **resume re-checks permission** |
| flash | the cycle reaches the torch; a fresh controller is set explicitly even to `off`; a chosen mode survives a lens switch; the torch times out; a sensor with no LED falls back once |
| zoom | slider value clamped to range; **pinch measured from its origin, not compounded**; a zoom that has not moved is never sent to the platform |
| quick-zoom stops | **a single rear camera that can zoom still gets a row**; a reachable ratio just sets the zoom; an unreachable one opens the rear camera that can |
| focus | reticle shown and normalised coordinates forwarded; out-of-bounds tap clamped |
| capture and batching | each press adds one shot; failed capture adds no phantom shot; **a discard leaves the batch *and* the disk**; discarding an unknown id deletes nothing; submit hands every shot to the queue and starts a fresh batch; empty batch is a no-op |
| lens selection | switching re-opens and bumps `previewKey`; the front camera is never a zoom-stop candidate |

`zoom_stop_test.dart` — 12 tests over the pure `ZoomLadder` policy: which stops each sensor
range earns, the ultra-wide threshold, the three-button cap, garbled ranges, and which stop is
lit at a given zoom.

`camera_chrome_test.dart` — 10 widget tests on the controls themselves: the quick-zoom row
renders and reports taps, the selected pill shows the live zoom between stops, a
single-stop sensor gets no row, the slider labels both ends and **zooms in when dragged
upwards**, a sensor that cannot zoom gets no slider, the batch badge appears only with shots,
and a disabled shutter does not fire.

```bash
cd flutter && flutter test test/presentation/capture/ test/domain/zoom_stop_test.dart
```
