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
 * The screen's single source of truth: one cold [Flow] that fuses the saved
 * anchor, the live position stream and today's attendance record into an
 * [AttendanceStatus].
 *
 * Three details are worth calling out:
 *
 *  1. The position stream is prefixed with a `null` via [onStart]. `combine`
 *     will not emit until *every* source has produced a value, so without this
 *     the whole screen would stay blank until the first GPS fix arrives -
 *     which on a cold start can be 20 seconds. With it, the office card and
 *     any permission error render immediately.
 *  2. [scan] threads the previous [ProximityStatus] and the last known
 *     [LocationFix] forward. The first powers the exit hysteresis, which a
 *     stateless `map` could not do; the second is what lets the dial keep
 *     reading during a location dropout *and* re-measure the moment the user
 *     moves the office.
 *  3. "Today" is recomputed on every emission rather than captured at
 *     subscribe time, so a session left open across midnight re-arms
 *     correctly instead of reporting yesterday's check-in.
 */
class ObserveAttendanceStatusUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val locationTracker: LocationTracker,
    private val attendanceRepository: AttendanceRepository,
    private val geofenceEvaluator: GeofenceEvaluator,
    private val timeProvider: TimeProvider,
    private val window: AttendanceWindow = AttendanceWindow.Default,
) {

    private data class Inputs(
        val anchor: Outcome<OfficeAnchor?>,
        val fix: Outcome<LocationFix>?,
        val history: List<AttendanceRecord>,
    )

    operator fun invoke(intervalMillis: Long = LocationTracker.DEFAULT_INTERVAL_MILLIS): Flow<AttendanceStatus> {
        val anchorFlow = officeAnchorRepository.observe()

        val fixFlow: Flow<Outcome<LocationFix>?> = locationTracker.stream(intervalMillis)
            .map<Outcome<LocationFix>, Outcome<LocationFix>?> { it }
            .onStart { emit(null) }

        val historyFlow = attendanceRepository.observeHistory().onStart { emit(emptyList()) }

        return combine(anchorFlow, fixFlow, historyFlow) { anchor, fix, history ->
            Inputs(anchor, fix, history)
        }
            .scan(Carried(AttendanceStatus.initial(window), lastFix = null)) { previous, inputs ->
                reduce(previous, inputs)
            }
            .drop(1) // discard the seed; the first real emission is index 1
            .map { it.status }
    }

    /**
     * What the scan threads forward: the projection, plus the last position we
     * actually know about.
     *
     * Carrying the *fix* rather than the finished reading is what makes the
     * dial survive re-anchoring. The reading is an answer about one particular
     * office; reusing it after the office moves reports the distance to a
     * building the user no longer works in. The fix is raw enough to still be
     * true, so it can be measured again against whatever anchor is current.
     */
    private data class Carried(val status: AttendanceStatus, val lastFix: LocationFix?)

    private fun reduce(previous: Carried, inputs: Inputs): Carried {
        val anchor = (inputs.anchor as? Outcome.Success)?.value
        val storageError = (inputs.anchor as? Outcome.Failure)?.error as? AppError.Storage

        val locationError = (inputs.fix as? Outcome.Failure)?.error as? AppError.Location

        // A transient location error must not erase the last known distance -
        // the user still deserves to see how far out they were.
        val fix = (inputs.fix as? Outcome.Success)?.value ?: previous.lastFix

        // Hysteresis smooths jitter around *one* fence. Carrying a previous
        // status across a change of office would apply the wider exit radius
        // to a perimeter that state was never about, so the anchor change
        // resets it.
        val isSameAnchor = previous.status.anchor?.point == anchor?.point

        val reading = if (anchor != null && fix != null) {
            geofenceEvaluator.evaluate(
                anchor = anchor,
                fix = fix,
                previousStatus = previous.status.reading?.status.takeIf { isSameAnchor },
            )
        } else {
            null
        }

        val today = timeProvider.localDate()
        val todayRecord = inputs.history.firstOrNull { record ->
            Instant.ofEpochMilli(record.markedAtEpochMillis)
                .atZone(timeProvider.zone())
                .toLocalDate() == today
        }

        return Carried(
            status = AttendanceStatus(
                anchor = anchor,
                reading = reading,
                locationError = locationError,
                storageError = storageError,
                todayRecord = todayRecord,
                window = window,
                isWindowOpen = window.contains(timeProvider.localTime()),
            ),
            lastFix = fix,
        )
    }
}
