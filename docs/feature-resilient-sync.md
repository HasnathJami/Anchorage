# Feature — Resilient Sync Engine (Anchorage Harbor)

*Task 2 of the brief, second half. Flutter, BLoC, sqflite, WorkManager, connectivity_plus.*

> **Brief:** *"Implement a background worker to monitor connectivity. If the API call fails
> due to low bandwidth or no internet, the images must remain in the local queue.
> Automatically retry the upload once a stable connection is detected without user
> intervention."*

This is the most demanding sentence in the assessment, and this document explains exactly how
each clause is satisfied.

---

## 1. The six rules

`ProcessUploadQueue` states its rules in its own doc comment. Every one has a test group named
after it, and every test fails if the rule is removed.

### Rule 1 — Never start without a *stable* link

If the link is offline or has not settled, **every eligible task is parked in
`waitingForConnection` without spending an attempt**, and a network-constrained wake-up is
requested from the OS.

This is what turns "no internet" into a *pause* rather than five wasted retries.

### Rule 2 — One task at a time

Serial, not parallel. Parallel uploads on a weak link starve each other, bound memory poorly
on large files, and contradict the reference UI, which shows exactly one row transferring.

### Rule 3 — Connectivity failures do not consume attempts

Losing the signal mid-transfer parks the task. Only a genuine transport or server error
increments the counter and schedules backoff.

*Why this matters:* five tunnels would otherwise exhaust the retry budget and mark a
photograph permanently failed — while sitting on a perfectly good phone with a perfectly good
file.

### Rule 4 — Unretryable failures stop immediately

A missing file or an HTTP 400 will never succeed. The task fails once and is surfaced with a
manual retry control, rather than looped with exponential backoff.

### Rule 5 — The queue is the source of truth throughout

Every transition is written before the next task starts, so process death mid-sweep loses at
most the bytes of one in-flight upload — never the queue itself.

### Rule 6 — A task is claimed before it is uploaded

`ProcessUploadQueue` has always carried a `bool _inFlight` guard against a manual "sync now"
racing the periodic worker. That guard is real, and it is not enough: the WorkManager sweep
runs in a **separate isolate** with its own `Injector.configure()`, its own repository and its
own instance of this use case. Neither side can see the other's flag. Two sweeps could read
the same eligible row and upload the same photograph twice — which, on a metered link, costs
a real person real money.

The claim closes it, as one conditional statement:

```sql
UPDATE upload_tasks
   SET status = 'uploading', claimed_at = ?, throughput_bps = NULL
 WHERE id = ?
   AND status IN ('queued', 'waitingForConnection', 'retrying')
```

SQLite serialises writers, so of two racing sweeps exactly one sees `updated == 1`. The loser
sees `0` and moves on without counting an attempt. Doing this as a read-then-write in Dart
would reintroduce the very window it exists to close.

**The mirror-image hazard is worse, and needs the other half.** A row is marked `uploading`
before its bytes move. Kill the process at that instant — the user swipes the app away,
Android reclaims memory — and the row stays `uploading` forever. `uploading` is not an
eligible state, so `readEligible` never returns it again: that photograph is silently
stranded, and the queue looks healthy while doing nothing.

So a claim is a **lease**, not a flag. `claimed_at` records when it was taken;
`updateProgress` renews it, so a 1.2 GB scan crawling over mobile data is never mistaken for
a corpse. At the top of every sweep, anything claimed longer than `staleClaimAfter`
(ten minutes) ago goes back to the queue from byte zero — the transport has no resume token,
so half a file already sent is half a file that has to go again, and claiming otherwise would
leave the progress bar lying.

Ten minutes is deliberately generous. Reaping too early costs a duplicate upload; reaping too
late costs one extra sweep of waiting.

---

## 1a. What starts a sweep

The rules above describe what a sweep *does*. When one begins is a separate question, and
getting it wrong produces an engine that is correct on paper and looks dead on screen.

| Trigger | Owner | Why it is needed |
| --- | --- | --- |
| App launch | `UploadManagerBloc._onStarted` | Drains a queue left behind by a previous run |
| The link becomes **stable** | `UploadManagerBloc._onLinkChanged` | The brief's requirement in one line: retry automatically, no user action |
| **New work is queued** | `UploadManagerBloc._onQueueUpdated` | Without it, tapping `UPLOAD BATCH` on an already-stable link uploaded nothing until WorkManager next woke — the rows sat at `IN QUEUE` for minutes |
| **A backoff elapses** | `UploadManagerBloc._scheduleBackoffWake` | A retry scheduled four seconds out had no foreground trigger, so the row read `RETRYING...` and then did nothing until the 15-minute periodic sweep |
| OS wake-up, app closed | `WorkManagerScheduler` | The whole app-not-running case |

Only the first two existed at first. The last two are the difference between an engine that
*is* resilient and one that *looks* it.

Both new triggers needed a fix underneath them. `claim` and `requeueStalled` used to
republish the queue unconditionally, and the reaper runs at the top of *every* sweep — so
"sweep when the queue changes" plus "always announce a change" is an infinite loop. They now
notify only when they actually change a row, which is the correct behaviour anyway.

`_hasWorkReadyNow` is the guard on the queue-update trigger, and every clause in it is
load-bearing:

* **not paused** — the user said stop.
* **not already sweeping** — `droppable()` would drop the event anyway; this keeps the
  intent explicit.
* **the link can transfer** — otherwise parking a task for want of a network republishes the
  queue, which starts a sweep, which parks it again.
* **something is ready *now*** — a task sitting out its backoff must not be swept
  continuously until the backoff elapses, which is the opposite of what backoff is for.

---

## 2. The task state machine

```
                  ┌──────────┐
   enqueue ──────►│  queued  │
                  └────┬─────┘
                       │ picked up, link stable
                       ▼
                 ┌───────────┐   success    ┌────────┐
                 │ uploading │─────────────►│ synced │  (terminal)
                 └─────┬─────┘              └────────┘
        no link │      │ retryable error         │ unretryable / budget spent
                ▼      ▼                         ▼
   ┌────────────────────────┐   ┌──────────┐  ┌────────┐
   │ waitingForConnection   │   │ retrying │  │ failed │  (terminal)
   │ attempt NOT spent      │   │ backoff  │  └───┬────┘
   │ backoff CLEARED        │   └────┬─────┘      │ user taps retry
   └───────────┬────────────┘        │            │ (attempt budget reset)
               │ link returns        │ deadline   ▼
               └─────────────────────┴──────────► queued

   any non-terminal ──[PAUSE ALL]──► paused ──[RESUME ALL]──► queued
```

Only `queued`, `waitingForConnection` and `retrying` are eligible for pickup, and only when
`nextAttemptAt` has elapsed. `uploading`, `paused`, `synced` and `failed` are not.

---

## 3. "Stable" is not "connected"

The brief's word is doing real work.

`connectivity_plus` reports a link the **instant** the OS associates with a network —
typically several seconds before it can carry a byte (DHCP, captive-portal probes, a train
leaving a tunnel with one bar). An engine that starts uploading on the first `connected`
event fails immediately and burns an attempt, every single time.

`ConnectivityMonitor` therefore models three states:

| State | Meaning | Engine |
| --- | --- | --- |
| `offline` | No transport at all | Park |
| `unstable` | Transport exists, has not held long enough | Park |
| `stable` | Held continuously for the settle window (3 s) | Transfer |

* A new link is admitted as `unstable`. A timer promotes it to `stable` after the window.
* **Any drop cancels the timer**, so a flapping link is never promoted.
* Demotion is instant.

Being pessimistic quickly and optimistic slowly is the correct asymmetry when a false "stable"
costs a wasted attempt.

Multiple simultaneous transports (Wi-Fi + mobile during a handover) resolve by capability:
ethernet › Wi-Fi › mobile › VPN.

**One exception:** in a cold background isolate the monitor has no history, so
`current()` samples directly and treats the result as stable — because WorkManager only
launched the task *at all* because its network constraint was already satisfied. The OS has
effectively vouched for the link.

---

## 4. Retry: exponential backoff with full jitter

```
attempt 1 → uniform in [0,  4 s]
attempt 2 → uniform in [0,  8 s]
attempt 3 → uniform in [0, 16 s]
attempt 4 → uniform in [0, 32 s]
…                     capped at 15 min
```

**Why jitter, specifically.** Twelve photographs fail *together* the moment a tunnel swallows
the signal. With plain exponential backoff all twelve wake at exactly the same millisecond,
hit the server together, and — if the server was the problem — knock it over again. Full
jitter (uniform across `[0, computed]`) minimises both collision and total wait.

The `Random` is injected, so the schedule is deterministic in tests. The tests assert on the
**ceiling** and, separately, on the **variance across seeds** — never on a sampled value,
because pinning one output tests the seed rather than the policy.

**Budget:** 3 attempts, from `RetryPolicy.defaultMaxAttempts`. `maxAttempts` is stored
per-task, so a future large-file policy could differ, but the default is the single source of
truth: `UploadTask.defaultMaxAttempts` and the queue table's own column default both follow
it, and a v3 migration brought older rows into line. A row that says `2/3` and an engine that
stops at three must be reading the same number.

Three rather than five because of what the number *counts*. An attempt is only spent on a
failure that was the task's own — a rejection from the server, a transport that broke for a
reason the radio cannot explain. **Losing the network costs nothing, and neither does a link
too slow to carry the file**: both park the row indefinitely without touching the counter. So
the budget is only ever spent on failures repeating for the same reason, and by the third of
those the fourth is not going to be the one that works. Stopping there, saying so, and
offering a manual retry is a better use of the battery and of the server.

---

## 5. Foreground and background: the same engine, twice

```
   ┌────────────────────────┐         ┌────────────────────────────┐
   │  App open              │         │  App closed / killed        │
   │  UploadManagerBloc     │         │  WorkManager isolate        │
   │  reacts to the link    │         │  syncCallbackDispatcher     │
   │  becoming stable       │         │                             │
   └───────────┬────────────┘         └──────────────┬──────────────┘
               │                                     │
               └──────────► ProcessUploadQueue ◄─────┘
                            (one implementation)
```

Duplicating the rules in two places would be the obvious mistake. `ProcessUploadQueue` has
**no UI dependency at all**, which is exactly what allows both callers.

Overlap is safe because of the `_inFlight` guard: a concurrent call returns
`SyncSweepReport.idle` rather than uploading the same file twice.

### The two WorkManager jobs

| Job | Trigger | Purpose |
| --- | --- | --- |
| `periodicSweep` | Every 15 min (OS minimum), `NetworkType.connected` | The safety net: the app may never be opened again, and the photographs must still leave the device. |
| `opportunisticSweep` | One-shot, `NetworkType.connected` | The requirement proper: the **OS** watches the radio and wakes the app. Far cheaper and more reliable than an in-process listener, which dies with the app. |

`ExistingPeriodicWorkPolicy.keep` makes registration idempotent — calling it on every cold
start does not reset the interval or stack duplicates.

`ExistingWorkPolicy.keep` on the one-shot collapses a burst (twelve files enqueued at once)
into a **single** scheduled wake-up.

**Ordering matters:** `EnqueueBatch` commits the rows to SQLite *before* asking for a wake-up.
Reversed, the worker could run, find an empty queue and go back to sleep — and the batch would
then wait for the next periodic sweep.

### The isolate's contract with the OS

`Workmanager().executeTask` returns a boolean that means something specific:

* `true` → "done, do not wake me again"
* `false` → "retry me with backoff"

Returning `true` after a failure is **the** reason most background-sync implementations
quietly stop working after the first bad network. Anchorage returns
`!report.shouldReschedule` for the one-shot, and always `true` for the periodic task so its
own cadence is preserved.

Three more isolate-specific rules, each a common source of "works in debug, silently does
nothing in release":

1. **The isolate starts empty.** No `main()` has run, no service locator exists, no plugin is
   registered. `WidgetsFlutterBinding.ensureInitialized()` and a fresh `Injector.configure()`
   are mandatory.
2. **Background scheduling is disabled inside it** (`enableBackgroundScheduling: false`).
   Scheduling WorkManager work from inside a WorkManager task builds an accidental wake-up
   loop. Intent is expressed through the return value instead.
3. **Nothing may throw.** An escaped exception is reported to the OS as a crash and can get the
   app's background execution throttled.

---

## 6. The queue

SQLite via `sqflite`. Chosen over a JSON file or shared preferences for one reason that
outweighs the rest: **atomic, durable single-row updates.** A progress tick fires several
times a second; rewriting a whole document that often is slow, and a crash mid-write loses the
entire queue.

```sql
CREATE TABLE upload_tasks (
  id                 TEXT PRIMARY KEY NOT NULL,
  batch_id           TEXT NOT NULL,
  file_path          TEXT NOT NULL,
  display_name       TEXT NOT NULL,
  size_bytes         INTEGER NOT NULL,
  created_at         INTEGER NOT NULL,
  status             TEXT NOT NULL,
  attempt            INTEGER NOT NULL DEFAULT 0,
  max_attempts       INTEGER NOT NULL DEFAULT 5,
  bytes_transferred  INTEGER NOT NULL DEFAULT 0,
  next_attempt_at    INTEGER,
  failure_kind       TEXT NOT NULL DEFAULT 'none',
  throughput_bps     INTEGER,
  completed_at       INTEGER,
  claimed_at         INTEGER          -- schema v2: the upload lease
);

CREATE INDEX idx_queue_pickup ON upload_tasks (status, next_attempt_at, created_at);
CREATE INDEX idx_queue_batch  ON upload_tasks (batch_id);
```

`idx_queue_pickup` serves the engine's hot query: *"what may I attempt now, oldest first."*

**Enums are persisted by name, never by index.** An index would silently re-map every stored
row the day someone inserts a case in the middle of the enum — the kind of bug that corrupts a
user's queue and is invisible in review. Unknown values on read degrade to a safe default
rather than throwing: a queue that refuses to open because one row holds a status from a newer
build is a far worse outcome than one row reading as `queued`.

**Change notification is explicit.** `sqflite` has no reactive queries, so every write calls
`_notify()`, which re-reads and pushes to a broadcast stream. Honest and cheap for a queue of
tens of items, and it keeps "who republishes?" answerable by reading one file.

**Enqueue is one transaction.** A batch is either queued or it is not; a half-enqueued batch
would upload some photographs of a site and silently drop the rest.

---

## 7. The mock transport

The brief states no API is available and permits either commenting out the API classes or
hard-coded mock responses. Anchorage does **both**.

### `MockUploadApi` — a working transport

Not a stub. It streams realistic progress at a configurable throughput and returns the whole
typed failure taxonomy:

| Behaviour | Produces | Engine reaction |
| --- | --- | --- |
| `succeed` | Full transfer | `synced` |
| `failLowBandwidth` | `LowBandwidthFailure` at 45 % | **parked**, no attempt spent |
| `failNoConnection` | `NoConnectionFailure` | **parked**, no attempt spent |
| `fail` | `ServerFailure(500)` | `retrying`, attempt +1, jittered backoff |
| `failServerPermanent` | `ServerFailure(400)` | `failed` on the **first** attempt |
| `hang` | Never answers | caller's timeout |
| `flaky` | Weighted random mix | soak test |

Failures occur **part-way through**, not at byte zero — that is the case that exercises
partial-transfer handling. It also checks the file still exists (returning
`MissingArtifactFailure`, which is terminal) and honours the real link when one is wired in,
so pulling a device off Wi-Fi during a demo produces a genuine failure rather than a scripted
one.

### `http_upload_api.dart` — the real transport, commented out

Written in full so a reviewer can see what would ship, including the details that matter for
resilience:

* a **streamed** body — a 1.2 GB file never sits in memory;
* an **idempotency key**, so a retry after an ambiguous timeout cannot create a duplicate
  server-side record;
* status classification: 408/429/5xx retryable, other 4xx permanent;
* `SocketException` → `NoConnectionFailure`, which the engine treats as *park*, not *attempt
  spent*.

Switching is one line in `injector.dart`.

### The in-app switcher

**Two** chips inside the camera's settings sheet change the mock's behaviour at runtime:
`SUCCESS` and `FAILED`. Nothing in the engine reads the setting.

Two, and not more, because a server has two things to say about an upload — it took the
file, or it did not. The switcher used to carry `LOW BANDWIDTH` and `NO INTERNET` as well,
and those were removed on purpose: **they are conditions of the link, not answers from a
server**, the app now reads both from the device itself, and a scripted copy of them
demonstrated nothing except that a switch works.

| Chip | What happens |
| --- | --- |
| `SUCCESS` | The far end accepts the file. Whether the upload *completes* still depends on the link — an offline device still fails, and a link too slow to carry the file still parks. |
| `FAILED` | The far end rejects it, part-way through, however good the link is. A retryable `500`, so `RetryPolicy` decides when enough is enough: the attempt counter climbs with jittered backoff and the row ends at `FAILED` with a manual **Retry**. |

The rejection is deliberately retryable rather than a permanent `4xx`. A mock that decided
"this one is final" would be duplicating a judgement `RetryPolicy` already owns, and there
should be exactly one thing in this codebase that decides when to stop trying.

### Where "no internet" and "low bandwidth" come from instead

Both are read from reality, which is the only way either is worth demonstrating:

| Condition | Source | What the engine does |
| --- | --- | --- |
| No internet | `ConnectivityMonitor` over `connectivity_plus`, plus WorkManager's network constraint for the app-closed case | Rule 1: park every eligible task in `waitingForConnection`, spend no attempt, ask for a network-constrained wake-up |
| Low bandwidth | **Measured** throughput from the bytes actually moving, judged by `BandwidthPolicy` | Cancel the transfer, park the task, spend no attempt |

The second one exists because the operating system will tell you there is a transport and
will never tell you it is useless. A phone on one bar, or on a hotel Wi-Fi behind a saturated
uplink, is `connected` by every signal Android exposes while a 300 KB photograph takes four
minutes and usually dies before it lands. So `ProcessUploadQueue` watches the throughput its
own progress callback reports, and if it stays under `BandwidthPolicy.floorBytesPerSecond`
for the whole of `BandwidthPolicy.grace`, it cancels the transfer and parks the row.

Three details are load-bearing:

* **The grace window measures a *continuous* slow spell.** One good tick clears it. TCP
  slow-start, a lift, and a Wi-Fi roam all produce a second or two of nothing on a link that
  is about to be fine, and parking those would abandon transfers that were going to work.
* **It parks rather than failing.** The file is fine and the server is fine; the network is
  not. Spending a retry attempt on that burns the budget the task needs later.
* **The watchdog lives in the use case, not the transport.** It is a product decision about
  what "too slow" means, so it applies to `MockUploadApi` and to a real HTTP client alike,
  and it is asserted on the JVM rather than discovered on a train.

It lives there rather than on the Upload Manager because the reference design's bottom bar
carries one button and nothing else. The switcher is the one place the presentation layer
reaches past a port to a concrete adapter, and the architecture test names the file so a
second such reach cannot appear quietly.

---

## 8. The Upload Manager screen

Transcribed from the reference: title row with the link chip, batch progress header on a
raised panel, `PENDING UPLOADS (n)` list, and a blue call to action pinned to the bottom.

| Element | Behaviour |
| --- | --- |
| Link chip | `STABLE LINK` (green) / `WEAK LINK` (amber) / `NO LINK` (red) |
| Progress bar | Byte-weighted, derived from the queue |
| `PAUSE ALL` / `RESUME ALL` | Holds every non-terminal task; automatic sweeps are suppressed while paused |
| Active row | Lifted surface, blue hairline, inline progress bar, live throughput |
| `WAITING FOR CONNECTION` | Amber |
| `RETRYING... (ATTEMPT 3/3)` | Red |
| `SYNCED` | Green with a check |
| `FAILED` | Red, with per-row **retry** and **discard** controls |
| `CLEAR SYNCED` | Housekeeping, appears only when there is something to clear |
| File name | Stem in white, extension muted — the reference's own treatment, and what makes a column of near-identical generated names scannable |
| Delivered row | Dimmed to 55 %: kept visible, because "did that one actually land?" is the question this screen answers, but not competing with rows that still need something |
| `START NEW UPLOAD BATCH` | Pops back to the camera, or replaces the route when the Upload Manager is the only one on the stack — otherwise the screen's single call to action would be inert after a process death |

**Progress is measured in bytes, not item count.** One 1.2 GB scan among four thumbnails would
otherwise read as "80 % done" the moment the thumbnails land. A synced task counts its full
size even if the last tick was lost, so the bar always reaches the end when the queue drains.

The screen deliberately has **no prominent "upload now" button**. The engine is autonomous;
a manual trigger in the primary position would imply otherwise. Manual controls exist as
secondary affordances.

---

## 9. Tests

42 tests cover the engine and its domain directly, plus 9 for the Bloc and 8 for its widgets.

**`process_upload_queue_test.dart`** — 25 tests, grouped by rule:

| Group | Tests |
| --- | --- |
| empty/ineligible queue | idle sweep; backoff not elapsed; paused skipped |
| rule 1 — stable link | park all when offline (attempt untouched); park when unstable with the right failure kind; wake-up requested; **stale backoff cleared** |
| happy path | upload and mark synced; FIFO order; progress recorded |
| rule 3 — connectivity | mid-transfer loss parks; low bandwidth same; **link dropping between files parks the remainder** |
| retryable | backoff scheduled and attempt incremented; budget exhaustion fails permanently; success on a later attempt |
| rule 4 — unretryable | 400 fails first attempt with no backoff; missing file terminal |
| rescheduling | wake-up requested while work remains; not requested on a clean drain |
| concurrency | a second sweep mid-flight is a no-op |
| storage | read failure surfaced, not swallowed |
| rule 6 — the claim | **a row another sweep won in the meantime is skipped, not sent twice**; **a task abandoned mid-transfer is re-queued, not stranded**; a transfer that is still moving is left alone by the reaper |

The claim tests need a repository whose eligibility read is deliberately out of date —
`_StaleReadRepository` returns every task regardless of status. That is exactly what a *real*
read looks like from the losing side of a race: correct when it was taken, stale by the time
the caller acts on it. Nothing but the atomic claim can close that window, so this is the only
honest way to test it.

**`sync_domain_test.dart`** — 17: backoff ceiling/cap/variance/budget, task progress and
eligibility, byte-weighted batch progress, failure retryability.

**`upload_widgets_test.dart`** — 8 widget tests: every status line in the reference's own
words (`WAITING FOR CONNECTION`, `UPLOADING - 45%`, `RETRYING... (ATTEMPT 2/3)`, `SYNCED`),
the dimmed delivered row, the stem/extension split on the file name, the link chip's three
states, and the progress header's percentage and pause control.

**`upload_manager_bloc_test.dart`** — 9, including the headline behaviour:

> *"a link becoming stable resumes the queue with no user action"* — starts offline, asserts
> the task parked with no attempt spent, emits `stable`, asserts it uploaded and synced.

and its counterpart:

> *"a merely-connected (unstable) link does not start a transfer"*.

```bash
cd flutter && flutter test
```
