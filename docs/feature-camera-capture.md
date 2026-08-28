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
│ (✕)                          ⚡    ⚙      │   close · flash · upload manager
│                  VISUAL                  │
│                                          │
│                                    ┌──┐  │
│                                    │3x│  │   vertical zoom slider
│           [ live preview ]         │▓ │  │   (labels inside the track)
│                                    │● │  │
│                                    │1x│  │
│                                    └──┘  │
│              (0.5) (1x) (2)              │   lens pills — real cameras only
│                                          │
│   ┌──┐(12)        ◯◯◯          (⟳)      │   thumbnail · shutter · flip
│   └──┘         LIVE VIEW                 │
│                                          │
│   [   ⚓  UPLOAD BATCH (12)          ]   │
└──────────────────────────────────────────┘
```

Chrome is translucent rather than solid, so the frame being composed stays visible
underneath — a solid button on a camera hides exactly the part of the shot it sits on.

---

## 2. Zoom — three input paths, one model

| Input | Event | Behaviour |
| --- | --- | --- |
| Pinch | `CameraPinchStarted` → `CameraPinchZoomed(scale)` | `baseZoom × scale` |
| Slider | `CameraZoomChanged(absolute)` | Absolute |
| Lens pill | `CameraLensSelected(lens)` | Re-opens the sensor |

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

### Lens pills come from the device's real cameras

Hard-coding `0.5 / 1 / 2` gives a single-lens budget phone three buttons, two of which do
nothing.

`_describeLenses` enumerates the actual back cameras. The `camera` plugin does not expose
focal lengths, so the mapping uses the platform's ordering convention (on both Android and
iOS the first back camera is the main one, and additional back cameras are the ultra-wide and
telephoto), then sorts into optical order for display.

A device with one back camera renders **no selector at all** — `CameraState.selectableLenses`
returns fewer than two entries and `LensSelector` collapses. The front camera is excluded from
the pills and reached from the flip button, matching the reference.

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

`camera_bloc_test.dart` — 18 tests:

| Group | Covers |
| --- | --- |
| startup and permissions | already granted; ask then open; soft denial stays askable; permanent denial switches remedy to Settings; no camera degrades |
| lifecycle | sensor released on background; re-opened on resume; **resume re-checks permission** |
| zoom | slider value clamped to range; **pinch measured from its origin, not compounded** |
| focus | reticle shown and normalised coordinates forwarded; out-of-bounds tap clamped |
| capture and batching | each press adds one shot; failed capture adds no phantom shot; discard removes; submit hands every shot to the queue and starts a fresh batch; empty batch is a no-op |
| lens selection | switching re-opens and bumps `previewKey`; front camera excluded from the pills |

```bash
cd flutter && flutter test test/features/capture/
```
