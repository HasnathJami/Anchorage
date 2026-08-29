# PROMPTS.md

> The brief: *"As using generative AI is pretty common so we do not discourage the use of
> these tools. However, to understand how you use it, it is mandatory to briefly explain how
> you used it in your project with some of the essential prompts you entered for this
> project."*

This file is that explanation, kept deliberately complete rather than brief. It records the
prompts that shaped Anchorage — **including the ones that produced wrong answers**, because
how a developer handles a wrong answer from an AI says considerably more than a list of the
ones that worked.

**Tool:** Claude (Opus 5) inside Claude Code, in a single working session.
**My role:** requirements, architecture, review, and the decision on every trade-off.
**The model's role:** implementation at speed, under those constraints.

---

## Table of contents

- [0. Working method](#0-working-method)
- [1. Understanding the brief before writing anything](#1-understanding-the-brief-before-writing-anything)
- [2. Naming and project identity](#2-naming-and-project-identity)
- [3. Architecture — decided before code](#3-architecture--decided-before-code)
- [4. Task 1: the geofence domain](#4-task-1-the-geofence-domain)
- [5. Task 1: data layer and error handling](#5-task-1-data-layer-and-error-handling)
- [6. Task 1: pixel-perfect Compose UI](#6-task-1-pixel-perfect-compose-ui)
- [7. Task 1: MVI and the ViewModel](#7-task-1-mvi-and-the-viewmodel)
- [8. Task 2: the sync engine](#8-task-2-the-sync-engine)
- [9. Task 2: connectivity and background work](#9-task-2-connectivity-and-background-work)
- [10. Task 2: camera](#10-task-2-camera)
- [11. Task 2: the mock API](#11-task-2-the-mock-api)
- [12. Corrections I had to make](#12-corrections-i-had-to-make)
- [12a. The reference-fidelity pass on Task 2](#12a-the-reference-fidelity-pass-on-task-2)
- [13. Documentation](#13-documentation)
- [14. What I deliberately did *not* delegate](#14-what-i-deliberately-did-not-delegate)

---

## 0. Working method

Three rules I held to throughout:

1. **Requirements before code.** The PDF was parsed, its embedded screenshots rendered at
   high zoom, and the reference palette sampled programmatically *before* a single file was
   written.
2. **Tests before implementation, for every rule.** Not for boilerplate — for rules. If a
   sentence in the brief describes behaviour, that sentence became a test name first.
3. **Verified, never assumed.** Every module built, every suite run. The numbers in the
   README are measured outputs, not estimates.

---

## 1. Understanding the brief before writing anything

> **"Read E:/IM."**

> **"On this there have to be a single project — inside there are two tasks, one native
> Android with Jetpack Compose and another Flutter (BLoC). Implement these with proper clean
> code + TDD, unit testing, and proper DI."**

Then, before any code:

> **"The PDF has embedded UI screenshots. Extract them and render the pages at high zoom so
> I can actually see the target design — the text layer alone cuts off mid-sentence at the
> zoom bullet, and I need the real pixels."**

> **"Now sample the dominant colours out of those screenshots programmatically. I want the
> palette transcribed from the reference, not eyeballed to the nearest Tailwind swatch."**

*Why this first:* "pixel perfect, same to same" was an explicit requirement. Sampling gave
`#2B6EEA`, `#F06363`, `#C8D2E1` for the Android screen and `#000514`, `#0F1428`, `#235FEB`
for the Flutter screens. Those odd values are in the code today.

> **"Before scaffolding anything, check what this machine actually has: Flutter version,
> JDK, Android SDK platforms and build-tools, and whether Maven Central and dl.google.com
> are reachable. Then query the maven metadata for the latest AGP, Kotlin, KSP, Hilt, Room
> and Compose BOM versions — I don't want a build file full of versions you remembered."**

*Why:* this caught that Hilt 2.60 requires AGP 9 before it cost a single failed build.

---

## 2. Naming and project identity

> **"For the project name implement a creative name — the brief says 'show your creativity'.
> It has to cover both apps under one identity, and the metaphor should actually mean
> something for both tasks, not just sound nice."**

The reasoning I accepted: **Anchorage** — a place a vessel holds position safely.
*Perimeter* anchors you to a place; *Harbor* anchors your cargo until it genuinely reaches
shore. The anchor is also literally the icon on the reference design's "UPLOAD BATCH" button.

---

## 3. Architecture — decided before code

> **"Multi-module clean architecture on the Android side. `:app`, `:core:common`,
> `:core:domain`, `:core:data`, `:core:designsystem`, `:feature:attendance`. Version catalog,
> no hard-coded versions in any build file."**

> **"Make `:core:domain` and `:core:common` plain `kotlin-jvm` modules, not Android
> libraries. I want 'the domain knows nothing about the framework' to be a compiler-enforced
> invariant, not a code-review convention. If someone imports `android.location.Location`
> into a use case, the build should break."**

> **"Give both apps a two-case sealed result type — `Outcome<T>` in Kotlin, `Result<T>` in
> Dart — over a closed error taxonomy. Not Kotlin's built-in `Result`: it carries a
> `Throwable`, which invites leaking platform exceptions upward. Failure should be data the
> compiler forces you to handle."**

> **"Every error case in the taxonomy must map to a *different* remedy on screen. If two
> cases would show the same message and the same button, they should be one case."**

---

## 4. Task 1: the geofence domain

> **"Write the geofence as a pure domain policy. Haversine implemented by hand — do not use
> `Location.distanceBetween`, that drags the Android SDK into the domain and forces every
> geofence test onto an emulator. Explain in the comment why Haversine's error is acceptable
> at this scale."**

> **"Use the `asin(sqrt(h))` form, not `atan2`, and clamp the argument with `min(1.0, …)`.
> Two identical points must not return NaN through floating-point drift — write a test named
> exactly that."**

> **"Add hysteresis. A naive `distance < 50` check will strobe the UI when a user stands on
> the boundary and GPS jitters by a few metres. Entry at 50 m, exit at 58 m. Thread the
> previous status through the Flow with `scan`, not a mutable field."**

Then the correction that mattered most:

> **"Wait — hysteresis must apply to the *dial only*, not to the actual check-in.
> `MarkAttendanceUseCase` judges against the true 50 m radius with no forgiveness. A
> forgiving indicator is good UX; a forgiving gate is a false attendance record. Write a test
> called 'hysteresis is not applied to the authoritative decision'."**

> **"`Location.accuracy` is a 68 % confidence radius and indoors it's routinely 50–150 m.
> Model it as a first-class part of the domain. `GeofenceReading` needs `isConfident`
> *separate from* `status` — 'inside at 12 m ± 90 m' and 'outside at 120 m ± 6 m' must be
> different states with different messages."**

> **"Anchoring the office needs a stricter accuracy bar than checking in — the anchor's error
> is inherited by every future comparison. And when it's rejected, put the actual numbers in
> the message."**

> **"The reference UI prints 'AVAILABLE 09:00 AM - 10:30 AM' under the button. Make that a
> real enforced business rule, not decoration. Both ends inclusive — 'closes at 10:30' means
> 10:30 works."**

> **"`MarkAttendanceUseCase` must re-validate everything and take a *fresh* fix. The disabled
> button is an affordance, not an enforcement boundary. Order the rejections cheapest-first
> so someone tapping at 4 p.m. is told instantly, not after a fifteen-second GPS wait."**

---

## 5. Task 1: data layer and error handling

> **"`FusedLocationTracker` must never throw. Every hardware, permission and connectivity
> fault becomes a typed `AppError.Location` delivered as a value. A Flow that throws tears
> down the collector and loses the hysteresis state built up above it."**

> **"Check permission and the location toggle *before* touching Play Services, and check
> permission first — if both are broken, telling someone to turn on location doesn't help
> them."**

> **"Enforce once-per-day in SQLite, not in Kotlin. Denormalise the local calendar date into
> a unique-indexed column and insert with ABORT. Application-level checks lose to races.
> ABORT not REPLACE — a duplicate is a violation to report, not something to paper over by
> overwriting the earlier, more truthful record."**

> **"'Which day is this?' must be answered in the device's local calendar, not UTC. A 2 a.m.
> check-in in Dhaka is 20:00 UTC the previous day. Write a test for a timestamp that crosses
> the UTC boundary."**

> **"DataStore over SharedPreferences, and say why in the comment. Handle the corrupt-file
> `IOException` *inside* the flow — unhandled it propagates to the UI collector and kills the
> screen. A partially written anchor must read as 'no anchor', never as a coordinate with
> zeroes standing in for the missing half."**

---

## 6. Task 1: pixel-perfect Compose UI

> **"Build the Attendance screen to match the reference screenshot exactly — same to same.
> White app bar with a blue back chevron and blue bold title; the STEP 1 card with a map
> thumbnail, a white coordinate pill, the body copy and a full-width outlined 'Set Office
> Location' button; the big ring dial with '120m' and 'AWAY'; the OUT OF RANGE pill; the
> helper sentence; and the dashed-border panel with the padlock, the disabled Mark
> Attendance button and the AVAILABLE caption."**

> **"Design-system module, not one-off styling. Semantic colour roles — `dangerArc`,
> `disabledContainer` — never raw pigment at a call site. A 4dp spacing ladder. A type scale
> named by role, not by a generic rung, and keep it to the seven treatments the reference
> actually uses."**

> **"For the map thumbnail: no Google Maps. It means a billed API key, a network round-trip
> and a second permission surface for decoration inside a card. Draw it procedurally on a
> Canvas, seeded from the anchor's coordinates — same office, same streets; different office,
> visibly different. Keep the 'this is your saved place' signal, drop the dependency."**

> **"Compose has no dashed border modifier. Draw it with `drawBehind` and a
> `PathEffect.dashPathEffect`, drawing *behind* the content rather than clipping so the
> dashes stay crisp at the corner radius."**

> **"Animate the dial's progress and colour. Raw GPS jitters several metres a second and
> without a tween the ring visibly twitches — the screen looks broken even when the data is
> fine. Enforce a minimum visible sweep so standing exactly on the anchor still renders a
> tick."**

> **"The dial must be one semantic node — 'You are 120m from the office'. A screen reader
> announcing '120' and 'AWAY' as unrelated nodes is useless. And no state may be carried by
> colour alone; every status gets a text label."**

---

## 7. Task 1: MVI and the ViewModel

> **"MVI: three types, three jobs. State is everything true right now. Intent is everything
> the user can do. Effect is the one-shot things — navigate, launch the permission dialog,
> show a snackbar. Keeping effects out of state is what stops a snackbar reappearing after
> every rotation."**

> **"State holds domain values — metres, timestamps, enums — never formatted strings.
> Formatting belongs to the composable that knows the locale, and keeping it out means the
> ViewModel tests never need a Context."**

> **"'Denied' and 'blocked' must be different screens with different actions. Read
> `shouldShowRequestPermissionRationale` *after* the dialog closes to tell them apart, and
> walk the ContextWrapper chain to find the Activity — don't assume the composition's context
> is one."**

> **"Persistent conditions get an inline banner, not a toast. Permission missing and location
> switched off are *states*; a Snackbar vanishes in four seconds and leaves a screen that
> looks inexplicably inert. Every banner carries an action — naming a problem without
> offering the fix is half an answer."**

> **"Don't use `stateIn(WhileSubscribed)` for the location stream. It'd keep the GPS warm
> whenever anything held a reference. Explicit start/stop job tied to permission."**

---

## 8. Task 2: the sync engine

> **"`ProcessUploadQueue` is the heart of this app. Write it with no UI dependency at all —
> the exact same use case has to run from the Bloc *and* from the WorkManager isolate where
> no widget tree exists."**

> **"State the engine's rules as a numbered list in the doc comment, then give me a test for
> each one that fails if the rule is removed. Name the test groups after the rules."**

> **"Rule one: never start without a *stable* link. If the link is offline or hasn't settled,
> park every eligible task without spending an attempt and ask the OS for a
> network-constrained wake-up. That's what makes 'no internet' a pause instead of five wasted
> retries."**

> **"Rule three is the subtle one: losing the network must not consume a retry attempt. Five
> tunnels would otherwise exhaust the budget and mark a photograph permanently failed while
> sitting on a perfectly good phone with a perfectly good file."**

> **"When you park a task, *clear* its backoff deadline. A parked task waits for an event,
> not a timer — a stale `nextAttemptAt` would delay it after the network came back. Test
> that."**

> **"Exponential backoff with full jitter, and explain *why* in the comment, not just that it
> is. Twelve photographs fail together when a tunnel swallows the signal; deterministic
> backoff wakes all twelve at the same millisecond."**

> **"Inject the `Random` so the schedule is deterministic under test. And the tests should
> assert on the *ceiling* and on the *variance* — never on a sample value. Testing a
> randomised policy by pinning one output is testing the seed, not the policy."**

> **"Distinguish retryable from permanent. A 400 and a missing file must fail on the first
> attempt and surface a manual retry control — looping them five times is a battery drain
> that ends in the same failure."**

> **"Serial uploads, one at a time, and re-check connectivity *between* files. A link can die
> mid-batch and continuing would burn an attempt on every remaining task."**

> **"Guard against the foreground Bloc and the background worker sweeping at the same time —
> otherwise the same file uploads twice."**

---

## 9. Task 2: connectivity and background work

> **"The brief says 'once a *stable* connection is detected'. That word is doing real work.
> `connectivity_plus` fires the instant the OS associates — seconds before the link can carry
> a byte. Three states, not two: offline, unstable, stable. Promote to stable only after the
> link has held continuously for a settle window, and demote instantly on a drop."**

> **"Two WorkManager jobs and be explicit about why each exists. Periodic is the safety net
> for 'the app is never opened again'. The one-shot with a `NetworkType.connected` constraint
> is the piece that actually satisfies the requirement — the OS watches the radio, which is
> far cheaper and more reliable than an in-process listener that dies with the app."**

> **"`ExistingWorkPolicy.keep` on the one-shot. Enqueuing twelve photographs must schedule
> one wake-up, not twelve."**

> **"Commit the queue rows *before* asking the OS for a wake-up. Reversed, the worker could
> run, find an empty queue, and go back to sleep."**

> **"The isolate's return value is a contract with the OS. `true` means 'done, don't wake me'.
> Returning `true` after a failure is *the* reason most background sync quietly stops working
> after the first bad network. Return `!shouldReschedule` for the one-shot; always `true` for
> the periodic so its cadence survives."**

> **"Disable background scheduling *inside* the isolate. Asking WorkManager to schedule more
> work from inside a WorkManager task is how you build an accidental wake-up loop."**

> **"Nothing may throw out of the isolate — an escaped exception is reported as a crash and
> can get the app's background execution throttled."**

---

## 10. Task 2: camera

> **"Put the whole `camera` plugin behind a `CameraPort`. `CameraController` can't be
> constructed on the Dart VM, so a Bloc that touches it directly could only be tested on a
> device. With the seam, every capture rule is covered by fast `flutter test` runs."**

> **"Release the sensor on pause and re-open on resume. Android hands the camera to whichever
> app asked most recently — holding it while backgrounded means a phone call leaves the user
> with a frozen black rectangle. Increment a `previewKey` so the widget rebuilds against the
> new controller rather than a disposed texture."**

> **"Resume must re-check permission. It can have been revoked from Settings while we were
> away."**

> **"Declare Bloc concurrency per event. Shutter is `droppable` — hammering the button must
> produce one photograph per completed capture, not twelve queued. Zoom is `restartable` —
> only the newest value matters and a pinch emits dozens a second."**

> **"Anchor the pinch to the zoom the gesture *started* at. Multiplying by the current zoom
> every frame compounds and the preview rockets to maximum. Write a test that sends the same
> scale twice in one gesture and asserts the zoom didn't move the second time."**

> **"Build the lens pills from the device's *actual* back cameras. Hard-coding 0.5/1/2 gives a
> single-lens budget phone three buttons, two of which do nothing. One sensor should mean no
> selector at all."**

> **"Hand-build the vertical zoom slider. A `RotatedBox`-wrapped Material `Slider` inverts its
> own gesture axis — dragging up decreases the value — and it can't put labels inside the
> track the way the reference does."**

> **"Move captured files out of the plugin's cache directory immediately. The OS clears that
> under storage pressure and a queued upload has to still find its bytes tomorrow morning."**

> **"Clamp zoom in the *adapter*, not the Bloc. The platform throws on an out-of-range value
> and a pinch gesture will absolutely produce one."**

---

## 11. Task 2: the mock API

> **"The brief says no API is available and to either comment out the API classes or use
> hard-coded mock responses. Do both, and make the mock a *working transport*, not a stub
> that returns true."**

> **"`MockUploadApi` streams realistic progress at a configurable throughput and returns the
> whole failure taxonomy — success, mid-transfer low bandwidth, no internet, retryable 503,
> permanent 400, and hang-until-timeout. Fail *part-way through*, not at byte zero; that's the
> case that exercises partial-transfer handling."**

> **"Have the mock honour the real link when one's wired in, so pulling the device off Wi-Fi
> during a demo produces a genuine failure rather than a scripted one."**

> **"Write out the real HTTP transport in full and comment it out. Include the things that
> actually matter for resilience: a streamed body so a 1.2 GB file never sits in memory, an
> idempotency key so a retry after an ambiguous timeout can't create a duplicate record,
> status-code classification, and a socket-level catch that maps to `NoConnectionFailure`.
> Say in the header that switching is one line in the injector."**

> **"Add a switcher at the bottom of the Upload Manager that changes the mock's behaviour at
> runtime. A reviewer should be able to *see* the resilience in ten seconds on a real device,
> not take the README's word for it."**

---

## 12. Corrections I had to make

The honest part. Each of these was a wrong or incomplete first answer that I caught and
corrected.

**a. Version choices made from memory.** The first build script used Hilt 2.60.1, which
requires AGP 9. Caught by an actual build, not by review. This is why I made the model query
Maven metadata for real version lists before writing any more build files — and why I pinned
AGP 8.13.2 / Kotlin 2.2.21 / Hilt 2.57.2 rather than "latest".

**b. A Flow type-widening error.** `locationTracker.stream().map { it }.onStart { emit(null) }`
does not widen `Flow<Outcome<T>>` to `Flow<Outcome<T>?>`; the compiler rejected it. Fixed with
an explicit type argument on `map`. Small, but a reminder that "it looks right" is not a
build.

**c. The notice-ownership bug — the one worth reading.** A test failed:
*"a coarse fix is refused with an explanatory banner and nothing is saved"* — the notice was
`null`. The cause was real, not a test artefact: the capture failure set the banner, and the
very next position update from the location stream overwrote it. On a device the user would
have seen a flash and no explanation.

My correction:

> **"This is a real bug, not a flaky test. The reducer is letting the ambient stream clobber
> a notice the user provoked. Define an ownership rule: the stream owns ambient notices and
> may clear them freely, but it may never overwrite one raised by the permission flow or by
> an explicit user action. Put the rule in a named predicate and comment *why*, so nobody
> deletes it in six months."**

That produced `isOwnedByUserAction()` and the comment now sitting in `AttendanceViewModel`.

**d. A DataStore test failing for the wrong reason.** The first version handed DataStore a
pre-created temp file; DataStore expects to create its own and read a zero-byte file as
corrupt. The test was failing on the harness, not the code.

> **"That failure is the test's fault, not the source's. Hand DataStore a *path* inside a temp
> directory, not an existing empty file, and run each case on the test's own
> `backgroundScope`."**

**e. A weak assertion I rejected.** The generated concurrency test asserted
`expect(repo.observeHistory().let { true }).isTrue()` — which cannot fail.

> **"That assertion proves nothing. Expose a synchronous snapshot on the fake and assert the
> double tap produced exactly *one* record."**

**f. A test that pinned randomness.** The first backoff test asserted an exact millisecond
value from a seeded `Random`.

> **"That tests the seed, not the policy. Assert the delay is within `[0, ceiling]` for each
> attempt, that it's capped, and — separately — that twelve different seeds produce more than
> one distinct value. That's what 'jitter' actually claims."**

**g. Dependency reality vs. the newest version.** `permission_handler 13` requires AGP 9 and
`compileSdk 37` and broke the Flutter Android build. Rather than dragging the whole Flutter
toolchain forward mid-assessment, I pinned `permission_handler 12.0.3`. Newest is not a
requirement; *building* is.

**h. A `dart:ui` type aliased instead of imported.** The camera adapter invented a
`typedef Offset` rather than importing the real one, which would have silently failed against
`setFocusPoint`. Caught by the analyzer.

---

## 12a. The reference-fidelity pass on Task 2

After the first build was complete and green, I went back to the brief's PDF and compared its
two Flutter screenshots against what the app actually rendered on a device. Several things did
not match. This section records that pass, because it is the most useful part of the log: the
model built what I asked for, and what I asked for was not quite right.

> **"Extract the two Flutter reference screenshots from the assessment PDF and read them at
> full magnification. Then go through `CameraPreviewPage` and `UploadManagerPage` control by
> control and tell me every place the implementation differs from the reference — layout,
> wording, and behaviour. Do not fix anything yet."**

The comparison surfaced one genuine defect and several smaller drifts. The defect was worth
the whole exercise:

> **"`LensSelector` builds the `0.5 / 1 / 2` row from `availableCameras()` and hides itself
> below two entries. Check that premise. What does `availableCameras()` actually return on a
> modern multi-lens Android phone?"**

It returns **one** rear camera — a *logical* camera whose zoom range spans the ultra-wide, the
main and the telephoto. So the row collapsed on nearly every device, and the reference
design's most recognisable control was empty space. The guard was sound; the premise was
wrong. The correction:

> **"Rebuild the row from the sensor's zoom range, not from the camera list. Put the rules in
> a pure `ZoomLadder` policy under `domain/entities/` so they are testable on the VM: 1x
> always present, a wide button only when the reported minimum is genuinely below 1x and
> aimed at that exact minimum rather than a round 0.5, higher stops only up to what the sensor
> reaches, capped at three. Keep physical lens switching, but only as a fallback for when the
> open camera cannot reach the requested ratio. Write the test that fails against the old
> implementation first."**

Two smaller ones from the same read:

> **"The reference render has the words `VISUAL` and `LIVE VIEW` floating over the preview.
> Those are artefacts of however that image was generated, not labels — and we transcribed
> them literally, so the app now announces `LIVE VIEW` across its own shutter button. Keep the
> layout slots; put something true in them."**

> **"The mock-response switcher sits in the Upload Manager's bottom bar, and the reference's
> bottom bar has one button and nothing else. Move it into the camera's settings sheet and
> update the architecture test's seam list with the reason — I do not want the count of
> presentation→data seams growing quietly."**

### The two bugs found by rendering the screens

I did not trust a read-through to catch layout problems, so:

> **"Write a throwaway widget test that renders both screens at 1080×2340 and writes them to
> PNG with `--update-goldens`, so I can look at them. Delete it afterwards — I do not want
> golden tests in this repo, they fail on every font tweak."**

That produced two overflow stripes: the Upload Manager's title row and its byte-count row both
fill the width on a 360 dp screen and exceed it at a large system text scale. Both are now
`Expanded` with the right half yielding — the title ellipsises, the link chip does not.

### The concurrency hole I went looking for afterwards

Having found one wrong premise, I checked the other one I had asserted early:

> **"`ProcessUploadQueue._inFlight` is an object field, and the WorkManager sweep runs in a
> separate isolate with its own `Injector.configure()`. Walk me through what stops the two
> from uploading the same file. If nothing does, fix it in the database, not in Dart."**

Nothing did. The fix is a conditional `UPDATE` that claims the row, plus — because the
mirror-image failure is worse — a lease, so a process killed mid-transfer does not strand its
row in `uploading` forever where `readEligible` will never see it again.

> **"The claim test has to simulate losing a race, and a fake that just returns eligible rows
> cannot. Write a repository whose `readEligible` is deliberately stale — that is exactly what
> a real read looks like from the losing side."**

### And one piece of dead code the comparison exposed

> **"`CameraShotDiscarded` has been in the event hierarchy since the first version and no
> widget dispatches it. Either delete it or give it the screen it was waiting for."**

It got the screen — `BatchReviewSheet` — because dropping a blurred frame *before* it becomes
durable queue work is a real saving for someone on a metered link. And discarding now deletes
the file, not just the list entry; the first version left every rejected photograph on the
device for good.

---

## 13. Documentation

> **"Every non-trivial comment must explain *why*, never *what*. If a reviewer could have
> guessed it from the code, delete it. I want the Haversine-over-`distanceBetween` rationale,
> the full-jitter rationale, the `@Binds`-over-`@Provides` rationale, the
> hand-built-slider rationale — all in the code where the decision lives."**

> **"Write `IMPROVEMENTS.md` as a numbered list. For each item: what the brief asked for, what
> the naive implementation would be, why that fails on a real device, and what we do instead.
> No entry without a concrete failure mode."**

> **"Write `PROMPTS.md` honestly. Include the prompts that produced wrong answers and what I
> said to correct them. Anyone can list the prompts that worked."**

---

## 14. What I deliberately did *not* delegate

* **Every architectural boundary.** The module graph, the pure-JVM domain, the port/adapter
  split, the MVI contract shape and the five rules of the sync engine were specified by me
  before any code existed.
* **Every trade-off with a real cost.** Hysteresis on the dial but not the gate. Mock
  locations reported but not blocked. `permission_handler` pinned back a major version.
  Procedural map instead of a Maps key. Each of those is a judgement call with a downside, and
  each is documented with its reasoning.
* **Acceptance.** Nothing was merged on the strength of "it looks right". Every Gradle module
  was built, every test suite executed, both APKs assembled. Where something failed — and
  several things did — the failure is recorded above rather than quietly fixed and forgotten.

The model made this fast. The decisions are mine, and I can defend every one of them.
