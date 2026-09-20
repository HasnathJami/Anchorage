package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.AttendanceStatus
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.ProximityStatus
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.scan
import java.time.Instant

/**
 * The attendance screen's **single source of truth**: one stream that fuses
 * three live inputs into one [AttendanceStatus], roughly twice a second.
 *
 * ```
 *   office anchor  ──┐
 *   GPS fixes      ──┼── combine ──► scan (adds memory) ──► AttendanceStatus
 *   history        ──┘
 * ```
 *
 * If you read one file to understand how the Android app works, read this
 * one. Everything the screen shows comes out of here.
 *
 * ## The four Flow operators used, in plain words
 *
 * - **`combine`** — "whenever *any* of these three changes, give me the
 *   latest value of all three". This is what makes the dial update when the
 *   GPS moves, *and* update when the office is changed, without any manual
 *   refresh.
 * - **`onStart { emit(null) }`** — pushes a placeholder in before the real
 *   values start arriving. Needed because of a `combine` gotcha explained
 *   below.
 * - **`scan`** — like `map`, but it can see the *previous* result. This is
 *   what gives the stream a memory, which two of the app's rules need.
 * - **`drop(1)`** — throws away `scan`'s seed value, which is a starting
 *   point rather than a real answer.
 *
 * ## Three details worth reading closely
 *
 * **1. The GPS stream is prefixed with a `null`.**
 * `combine` will not emit *anything* until **every** source has produced at
 * least one value. Without the `onStart { emit(null) }`, the whole screen
 * would stay blank until the first GPS fix arrived — which on a cold start
 * can take twenty seconds. With it, the office card and any permission error
 * render immediately, and the distance fills in when it is ready.
 *
 * **2. `scan` threads two things forward.**
 * The previous [ProximityStatus], which powers the exit hysteresis (a
 * stateless `map` could not do this — it has no memory of where the user just
 * was). And the last known [LocationFix], which is what lets the dial keep
 * reading through a GPS dropout *and* re-measure instantly when the user
 * moves their office.
 *
 * **3. "Today" is recomputed on every emission**, not captured when the
 * screen opened. A session left open across midnight therefore re-arms
 * correctly, instead of insisting the user already checked in — yesterday.
 *
 * @param officeAnchorRepository Source 1: the saved office.
 * @param locationTracker Source 2: live GPS fixes.
 * @param attendanceRepository Source 3: the history, to spot today's record.
 * @param geofenceEvaluator Turns (anchor, fix) into a distance and a verdict.
 * @param timeProvider Supplies "now" and "today". Injected for testability.
 * @param window The permitted check-in hours, reported so the UI can print
 *   them and so [AttendanceStatus.isWindowOpen] can be computed.
 */
class ObserveAttendanceStatusUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val locationTracker: LocationTracker,
    private val attendanceRepository: AttendanceRepository,
    private val geofenceEvaluator: GeofenceEvaluator,
    private val timeProvider: TimeProvider,
    private val window: AttendanceWindow = AttendanceWindow.Default,
) {

    /**
     * The three sources' latest values, bundled so `combine` can hand them to
     * `scan` as one object.
     *
     * @property anchor The saved office, or a storage failure.
     * @property fix The newest GPS reading. `null` means "none has arrived
     *   yet" — see detail 1 in the class docs.
     * @property history Every attendance record, used to find today's.
     */
    private data class Inputs(
        val anchor: Outcome<OfficeAnchor?>,
        val fix: Outcome<LocationFix>?,
        val history: List<AttendanceRecord>,
    )

    /**
     * Starts observing. Nothing happens until the returned [Flow] is
     * collected, and the GPS stops the moment collection is cancelled.
     *
     * @param intervalMillis How often to ask for a new GPS fix.
     * @param initialFix A position carried over from a previous subscription.
     *
     *   The stream is stopped whenever the screen leaves the foreground —
     *   that is what stops the battery drain — so without this the dial
     *   blanks to `--` on every return until a fresh fix arrives. On a cold
     *   radio that is several seconds, and it is exactly the moment the user
     *   is looking at it, having just set their office.
     *
     * @return A cold [Flow] of the complete screen state.
     */
    operator fun invoke(
        intervalMillis: Long = LocationTracker.DEFAULT_INTERVAL_MILLIS,
        initialFix: LocationFix? = null,
    ): Flow<AttendanceStatus> {
        // Source 1 - the saved office. Re-emits when the user changes it.
        val anchorFlow = officeAnchorRepository.observe()

        // Source 2 - GPS. The `onStart` prefix is detail 1 in the class docs:
        // without it, combine would wait for the first satellite before
        // letting the screen render anything at all.
        val fixFlow: Flow<Outcome<LocationFix>?> = locationTracker.stream(intervalMillis)
            .map<Outcome<LocationFix>, Outcome<LocationFix>?> { it }
            .onStart { emit(null) }

        // Source 3 - history. Same trick: an empty list up front means the
        // screen does not wait on a database read either.
        val historyFlow = attendanceRepository.observeHistory().onStart { emit(emptyList()) }

        return combine(anchorFlow, fixFlow, historyFlow) { anchor, fix, history ->
            Inputs(anchor, fix, history)
        }
            // `scan` gives the stream its memory. It starts from a seed and
            // feeds each result back in as `previous` on the next round.
            .scan(Carried(AttendanceStatus.initial(window), lastFix = initialFix)) { previous, inputs ->
                reduce(previous, inputs)
            }
            .drop(1) // discard the seed; the first real emission is index 1
            .map { it.status }
    }

    /**
     * What `scan` threads forward from one emission to the next: the
     * projection itself, plus the last position we actually know about.
     *
     * ## Why the *fix* is carried, not the finished reading
     *
     * This is what makes the dial survive re-anchoring.
     *
     * A [com.anchorage.perimeter.domain.policy.GeofenceReading] is an answer
     * about one particular office — "you are 40 m from the Dhaka office".
     * Reusing it after the office moves would report the distance to a
     * building the user has left.
     *
     * A [LocationFix] is raw enough to still be true no matter which office
     * is current, so it can simply be measured again. That is why tapping
     * "Set Office Location" updates the dial immediately rather than on the
     * next GPS tick.
     *
     * @property status The projection handed to the screen.
     * @property lastFix The newest real position, kept across dropouts.
     */
    private data class Carried(val status: AttendanceStatus, val lastFix: LocationFix?)

    /**
     * Turns the previous result plus the newest inputs into the next result.
     *
     * This is the whole business logic of the screen, and it is a pure
     * function: same inputs, same output, no I/O, no clock reads other than
     * through the injected [timeProvider]. That is what makes it testable in
     * milliseconds.
     *
     * @param previous What this function returned last time.
     * @param inputs The latest value from each of the three sources.
     * @return The next [Carried], whose `status` is what the screen renders.
     */
    private fun reduce(previous: Carried, inputs: Inputs): Carried {
        // Step 1 - unpack the anchor. It has two independent failure shapes:
        // "read failed" and "read fine, there just isn't one".
        val anchor = (inputs.anchor as? Outcome.Success)?.value
        val storageError = (inputs.anchor as? Outcome.Failure)?.error as? AppError.Storage

        // Step 2 - unpack the GPS result.
        val locationError = (inputs.fix as? Outcome.Failure)?.error as? AppError.Location

        // A transient location error must not erase the last known distance -
        // the user still deserves to see how far out they were. So on
        // failure, fall back to whatever position we last held.
        val fix = (inputs.fix as? Outcome.Success)?.value ?: previous.lastFix

        // Step 3 - decide whether hysteresis may carry over.
        //
        // Hysteresis smooths jitter around *one* fence. Carrying a previous
        // status across a change of office would apply the wider exit radius
        // to a perimeter that state was never about, so an anchor change
        // resets it.
        val isSameAnchor = previous.status.anchor?.point == anchor?.point

        // Step 4 - measure, if there is anything to measure. Both an office
        // and a position are required; either one missing means no reading,
        // and the dial shows `--`.
        val reading = if (anchor != null && fix != null) {
            geofenceEvaluator.evaluate(
                anchor = anchor,
                fix = fix,
                previousStatus = previous.status.reading?.status.takeIf { isSameAnchor },
            )
        } else {
            null
        }

        // Step 5 - has today already been marked?
        //
        // `today` is read fresh on every emission (detail 3 in the class
        // docs), and each record's UTC millis are converted into the user's
        // local calendar day before comparing - otherwise an early-morning
        // check-in would land on the wrong date.
        val today = timeProvider.localDate()
        val todayRecord = inputs.history.firstOrNull { record ->
            Instant.ofEpochMilli(record.markedAtEpochMillis)
                .atZone(timeProvider.zone())
                .toLocalDate() == today
        }

        // Step 6 - assemble the complete answer for the screen.
        return Carried(
            status = AttendanceStatus(
                anchor = anchor,
                reading = reading,
                locationError = locationError,
                storageError = storageError,
                todayRecord = todayRecord,
                window = window,
                isWindowOpen = window.contains(timeProvider.localTime()),
                radiusMeters = geofenceEvaluator.radiusMeters,
                lastFix = fix,
            ),
            lastFix = fix,
        )
    }
}
