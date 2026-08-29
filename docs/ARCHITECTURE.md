# Architecture

Both applications follow the same doctrine, expressed in each platform's idiom. This document
explains the shape, the reasons, and the trade-offs that were accepted.

---

## 1. The shape

```
            ┌───────────────────────────────────────────────┐
            │  PRESENTATION                                 │
            │  Compose screens / Flutter widgets            │
            │  AttendanceViewModel  ·  CameraBloc           │
            │  AttendanceHistoryVM  ·  UploadManagerBloc    │
            └────────────────────┬──────────────────────────┘
                                 │ depends on
            ┌────────────────────▼──────────────────────────┐
            │  DOMAIN                    (depends on NOTHING)│
            │  entities   GeoPoint, LocationFix, UploadTask │
            │  policies   GeofenceEvaluator, RetryPolicy,   │
            │             AttendanceWindow                  │
            │  ports      LocationTracker, UploaderPort,    │
            │             ConnectivityPort, CameraPort      │
            │  use cases  MarkAttendance, ProcessUploadQueue│
            └────────────────────▲──────────────────────────┘
                                 │ implements
            ┌────────────────────┴──────────────────────────┐
            │  DATA                                         │
            │  FusedLocationTracker · CameraPluginAdapter   │
            │  Room / DataStore     · SQLite queue          │
            │  ConnectivityMonitor  · WorkManagerScheduler  │
            │  MockUploadApi        · (HttpUploadApi)       │
            └───────────────────────────────────────────────┘
```

The domain is the innermost ring and knows nothing about Android, Flutter, Play Services,
SQL or HTTP. Everything outside it depends inward.

---

## 2. How the Android domain stays pure

The Android app builds from **one Gradle module**. Clean architecture is expressed as package
boundaries under `com.anchorage.perimeter`, and `domain/` still imports nothing but Kotlin,
`kotlinx.coroutines` and `core/common`.

An earlier revision split the domain and common code into separate `:core:domain` and
`:core:common` Gradle modules applying `org.jetbrains.kotlin.jvm`, which made that rule a
*compiler error* — a `kotlin-jvm` module cannot see the Android SDK at all. Collapsing to a
single module trades that guarantee
for a build a reader takes in at a glance: one `build.gradle.kts`, one source tree, one
`include(":app")`.

The rule is therefore restated as a test. `ArchitectureTest` walks the source tree and fails
on the first forbidden import, naming the file:

```
domain/ must not import android., androidx., com.google.android., dagger., javax.inject.
  — domain rules must stay unit-testable on the JVM with no device or stub
expected to be empty
but was: [MarkAttendanceUseCase.kt: import android.util.Log]
```

It covers five rules, one test each: the domain imports no framework and no outer layer,
`core/common` inherits the same purity rule, presentation never reaches into data, and data
never reaches into presentation.

**Be honest about the trade.** A test can be deleted; a missing Gradle dependency cannot. The
guard is also only as good as its reach, so a sixth test asserts the file walk actually finds
sources — without it every other rule would pass vacuously the moment the layout moved.

What survives unchanged: the domain still has no Android types, so its 48 tests still run on
the JVM in milliseconds with no emulator, no Robolectric and no instrumentation runner.

---

## 3. Package graph (Android)

```
com.anchorage.perimeter
├── AnchorageApplication.kt · MainActivity.kt   the composition root
├── di/                  UseCaseModule · DataModule
├── presentation/  ──┐
│   ├── attendance/  │   AttendanceViewModel · AttendanceScreen · component/
│   ├── history/     │   AttendanceHistoryViewModel · AttendanceHistoryScreen
│   └── navigation/  │   AnchorageNavHost
│                    ├──►  domain/   ◄──┐
├── data/  ──────────┘     ├── model/   │  entities
│   ├── local/room/        ├── policy/  │  GeofencePolicy · AttendanceWindow
│   ├── local/datastore/   ├── geo/     │  Haversine
│   ├── location/          ├── port/    │  repository + tracker interfaces
│   └── repository/  ──────┴── usecase/ ┘
└── core/
    ├── common/        Outcome · AppError · DispatcherProvider
    └── designsystem/  theme/ · component/
```

Three properties worth noticing, each of them a test in `ArchitectureTest`:

* **`presentation/` does not depend on `data/`.** It sees only domain use cases and ports. The
  binding of `LocationTracker` → `FusedLocationTracker` happens in `di/`, the composition
  root, so a ViewModel cannot accidentally reach for a `Room` DAO.
* **`data/` does not depend on `presentation/`.** An adapter that knows about a screen cannot
  be reused or tested in isolation.
* **`core/designsystem/` does not depend on `domain/`.** It has no business logic, so it has
  no reason to know what an `AttendanceRecord` is. It renders what it is handed.

### Why one module rather than several

The earlier split (`:core:common`, `:core:domain`, `:core:data`, `:core:designsystem`,
`:feature:attendance`, `:app`) bought compiler-enforced layering and finer incremental builds.
It cost six `build.gradle.kts` files, five `namespace` declarations and a dependency block
repeated per module — for a two-screen app, more Gradle than architecture.

The single module keeps the layering and pays for it with `ArchitectureTest` instead. What is
genuinely given up is incremental-build granularity: touching the design system now recompiles
the domain. At this size that is seconds, and it is the trade the Flutter app already makes —
`lib/` has no compiler-level boundary either, and neither app is worse for it.

If this grew to several teams and several features, splitting back out is the right move, and
the package structure is already shaped for it: each top-level folder is a module boundary
waiting to be drawn.

---

## 4. Directory graph (Flutter)

The same layer-first shape as Perimeter, in Dart's idiom. Capture and sync are two *features*
sharing one set of layers, exactly as attendance and history do on Android — they are folders
under `presentation/`, not parallel copies of the whole stack.

```
lib/
├── main.dart · app/         shell, routes            the composition root
├── di/                      injector (get_it)
├── background/              WorkManager isolate entry point
├── presentation/  ──┐
│   ├── capture/     │       CameraBloc · pages · widgets
│   └── sync/        │       UploadManagerBloc · pages · widgets
│                    ├──►  domain/   ◄──┐
├── data/  ──────────┘     ├── entities/│  UploadTask · CameraLens · RetryPolicy
│   ├── datasources/       │            │  FlashPolicy · LinkQuality
│   ├── models/            ├── services/│  ports: CameraPort · UploaderPort
│   ├── repositories/      │            │         ConnectivityPort · PermissionGateway
│   └── services/  ────────┼── repositories/
│                          └── usecases/   ProcessUploadQueue · EnqueueBatch
└── core/
    ├── designsystem/      HarborColors · HarborTypography · HarborTheme
    ├── error/             Failure taxonomy
    ├── result/            Result<T>
    └── utils/             Formatters
```

Dart has **no** module boundary at all — `lib/` is one library and any file may import any
other — so this doctrine used to be "enforced by review", which is another way of saying
enforced on whoever happens to be reading. It is enforced by `test/architecture/` now, the
mirror of Perimeter's `ArchitectureTest`:

* **`domain/` may import only `dart:`, Equatable, and the `Failure`/`Result` types.** An
  allowlist rather than a denylist, because the innermost ring is the one place where a new
  plugin sneaking in must be impossible rather than merely unlikely — a denylist only catches
  the plugins someone thought to name. `camera`, `sqflite`, `connectivity_plus`,
  `workmanager`, `permission_handler` and `package:flutter` itself appear only outside it.
* **`data/` never reaches up into `presentation/` or `app/`.**
* **`presentation/` never reaches down into `data/`**, apart from two seams listed by name in
  the test: the camera page needs the plugin's own `CameraController` to hand to
  `CameraPreview` (the widget *is* the adapter), and the camera settings sheet drives
  `MockUploadApi`'s canned-response switcher. Naming them means a third cannot appear quietly
  — when the switcher moved out of the Upload Manager, the seam moved with it and the count
  stayed at two.

Splitting `PermissionGateway` was part of this: the port now sits in `domain/services/` and
its `permission_handler` implementation in `data/services/`. They were one file, which meant
the plugin import travelled with the interface into every consumer — the exact coupling the
port exists to prevent.

---

## 5. Ports and adapters

Every external capability is a domain interface with a data-layer implementation.

| Port (domain) | Adapter (data) | Test double |
| --- | --- | --- |
| `LocationTracker` | `FusedLocationTracker` | `FakeLocationTracker` |
| `OfficeAnchorRepository` | `OfficeAnchorRepositoryImpl` (DataStore) | `FakeOfficeAnchorRepository` |
| `AttendanceRepository` | `AttendanceRepositoryImpl` (Room) | `FakeAttendanceRepository` |
| `TimeProvider` | `SystemTimeProvider` | `FixedTimeProvider` |
| `IdGenerator` | `UuidIdGenerator` | `SequentialIdGenerator` |
| `DispatcherProvider` | `StandardDispatcherProvider` | test dispatcher |
| `CameraPort` | `CameraPluginAdapter` | `FakeCamera` |
| `UploaderPort` | `MockUploadApi` / `HttpUploadApi` | `FakeUploader` |
| `ConnectivityPort` | `ConnectivityMonitor` | `FakeConnectivity` |
| `BackgroundSchedulerPort` | `WorkManagerScheduler` | `RecordingScheduler` |
| `UploadQueueRepository` | `UploadQueueRepositoryImpl` (SQLite) | `FakeUploadQueueRepository` |
| `PermissionGateway` | `PermissionHandlerGateway` | `FakePermissionGateway` |

This table *is* the testing strategy. Every one of those doubles exists, and it is why 174
tests run without a device.

---

## 6. Dependency injection

### Android — Hilt

* `DataBindingsModule` uses `@Binds` for every 1:1 interface→class mapping. `@Binds` compiles
  to a direct reference rather than a generated factory, and it makes the substitution
  greppable.
* `DataProvidersModule` uses `@Provides` only where Hilt cannot construct the object itself —
  `FusedLocationProviderClient`, the DataStore, the Room database.
* `UseCaseModule` lives in `di/` and assembles the domain. The use cases themselves carry
  **no framework annotations**: they are plain constructor-injected Kotlin classes a test can
  `new` in one line. That is what keeps `domain/` free of Hilt entirely.
* Policies (`GeofencePolicy`, `AttendanceWindow`) are *provided*, not defaulted at call sites,
  so a future per-tenant configuration is a one-file change.

### Flutter — get_it, hand-written

`Injector.configure()` is a hand-written composition root rather than a generated container.
That is deliberate: the interesting decisions in this app *are* the wiring — which transport
stands behind `UploaderPort`, whether background scheduling is real or a no-op, how long a
link must hold before it counts as stable. All of it should be readable in one file by anyone
auditing the app.

Every binding is against an interface, which is what makes the swap from `MockUploadApi` to
`HttpUploadApi` a single line.

The background isolate calls the *same* `Injector.configure()` with
`enableBackgroundScheduling: false` — see [feature-resilient-sync.md](feature-resilient-sync.md).

---

## 7. Presentation: MVI, twice

Both apps use unidirectional data flow with three distinct types.

| | Android | Flutter |
| --- | --- | --- |
| State | `AttendanceUiState` (`StateFlow`) | `CameraState`, `UploadManagerState` |
| Intent | `AttendanceIntent` | `CameraEvent`, `UploadManagerEvent` |
| Effect | `AttendanceEffect` (`SharedFlow`) | Bloc listener + `SnackBar` |

**Why effects are separate from state.** Stuffing a "show snackbar" flag into state means it
replays on every configuration change — the snackbar reappears after every rotation. Effects
are one-shot by construction.

**Why state holds domain values, not strings.** `AttendanceUiState` carries metres,
timestamps and enums. Formatting happens in the composable that knows the locale and the
available width. The consequence: `AttendanceViewModelTest` never needs a `Context`.

### Bloc concurrency is declared

Flutter's default transformer is `concurrent()`. Anchorage declares per event:

| Event | Transformer | Why |
| --- | --- | --- |
| `CameraShutterPressed` | `droppable()` | One photograph per completed capture |
| Zoom / pinch / focus | `restartable()` | Only the newest value matters |
| Lifecycle, lens | `sequential()` | Must not interleave |
| `UploadSyncRequested` | `droppable()` | A sweep is already in flight |

---

## 8. Threading and concurrency

* **Android:** every repository takes a `DispatcherProvider`; `withContext(dispatchers.io)`
  wraps disk work. The location stream uses `callbackFlow` + `flowOn(dispatchers.io)` with
  `awaitClose` removing the listener. `AttendanceViewModel` owns an explicit `observationJob`
  rather than `stateIn(WhileSubscribed)`, so GPS is never kept warm by an incidental
  reference.
* **Flutter:** `ProcessUploadQueue` is serial by design and guarded by an `_inFlight` flag,
  because the foreground Bloc and the WorkManager isolate both call it. Progress writes are
  fire-and-forget — awaiting them would throttle the transfer to the disk's speed, and a lost
  progress tick is cosmetic.

---

## 9. Persistence

| Data | Store | Why |
| --- | --- | --- |
| Office anchor (Android) | DataStore Preferences | Read as a *stream* — the screen must react the instant a new office is captured. Transactional writes mean a crash mid-save cannot leave a latitude without its longitude. |
| Attendance log (Android) | Room | Relational, queryable, and a **unique index** is what actually enforces once-per-day. |
| Upload queue (Flutter) | sqflite | Atomic, durable **single-row** updates. A progress tick fires several times a second; rewriting a JSON document that often is slow, and a crash mid-write loses the entire queue. |

Neither store uses a destructive migration fallback. Losing an attendance log or an upload
queue to a schema bump is a data-integrity incident, not a convenience.

---

## 10. Trade-offs accepted

| Decision | Cost | Why it was worth it |
| --- | --- | --- |
| Single-module Android | Layering guarded by a test, not the compiler; coarser incremental builds | One build file and one source tree to read; `ArchitectureTest` names the offending file on violation |
| Hand-written DI in Flutter | No compile-time graph validation | The wiring is the interesting part and should be readable |
| Serial uploads | Lower throughput on a fast link | Correctness on a weak link, bounded memory, matches the reference UI |
| Procedural map thumbnail | Not a real map | No API key, no billing, no network, no second permission surface |
| Sealed error taxonomies | More types to maintain | Exhaustiveness checking; a new failure cannot ship unexplained |
| Mock locations reported, not blocked | Weaker anti-spoofing | The app remains testable on an emulator; client-side blocking is defeatable anyway |
| `permission_handler` pinned to 12.x | Not the newest | 13.x requires AGP 9 and breaks the build |

---

## 11. What would change at production scale

Honest list, in the order I would do it:

1. **Modularise the Flutter app** the way the Android app is — separate packages for `core`,
   `capture` and `sync` with `dependency_validator` enforcing the import rules.
2. **Resumable uploads.** The queue already tracks `bytesTransferred`; the transport does not
   yet use it. Range requests would make a 1.2 GB file survive a dropped connection without
   restarting.
3. **A foreground service for large batches on Android 14+**, with the
   `dataSync` type already declared in the manifest, so long transfers are not deferred.
4. **Encrypted-at-rest capture storage**, if the photographs are genuinely evidential.
5. **Server-side geofence validation.** Client-side proximity is advisory; a real attendance
   system verifies on the server with the raw fix and its accuracy.
6. **Screenshot tests** (Paparazzi / `golden_toolkit`) to lock the pixel-perfect UI against
   regression.
