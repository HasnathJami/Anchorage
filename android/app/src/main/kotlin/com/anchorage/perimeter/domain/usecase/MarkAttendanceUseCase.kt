package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.core.common.outcome.flatMap
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.IdGenerator
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider
import kotlinx.coroutines.flow.first

/**
 * **"Mark Attendance"** — the authoritative decision that writes a record.
 *
 * This is the single most important class in the Android app. Everything else
 * exists to make its answer visible before the user taps.
 *
 * ## The five gates, in the order they are checked
 *
 * ```
 *  1. Is the clock inside the check-in window?        cheap, certain
 *  2. Has an office been set?                         cheap, certain
 *  3. Was attendance already marked today?            cheap, certain
 *  ─────────────────────── only now do we spend a GPS acquisition ───
 *  4. Is the fresh fix accurate enough to believe?    expensive
 *  5. Is the user actually inside the fence?          expensive
 *  ─────────────────────────────────────────────────────────────────
 *     Write the record.
 * ```
 *
 * ## Why re-validate what the button already checked?
 *
 * The button is only enabled when
 * [com.anchorage.perimeter.domain.model.AttendanceStatus.canMarkAttendance]
 * is true, so re-checking looks redundant. It is not.
 *
 * **A disabled button is a UI affordance, not an enforcement boundary.**
 * Between the moment the screen rendered and the moment the user taps, they
 * can walk out of the fence, the clock can cross the closing time, or a
 * second device can record the day. This use case is the only place the rule
 * is actually enforced.
 *
 * ## Why take a fresh fix instead of using the streamed one?
 *
 * Trusting the position already on screen would let a stale reading — or one
 * captured before the app was backgrounded — authorise a check-in from
 * anywhere. One deliberate round-trip to the positioning stack costs about a
 * second and removes that entire class of bug.
 *
 * ## Why the ordering matters
 *
 * The cheap, certain rejections run *before* the expensive GPS acquisition.
 * A user tapping at 4 p.m. when the window closed at 10:30 is told why
 * instantly, instead of watching a spinner for fifteen seconds to be told
 * something the app already knew.
 *
 * @param officeAnchorRepository Supplies the office to measure against.
 * @param attendanceRepository Enforces once-per-day, and stores the result.
 * @param locationTracker Supplies the fresh fix.
 * @param geofenceEvaluator Decides inside/outside and confident/not.
 * @param timeProvider Supplies "now" and "today". Injected for testability.
 * @param idGenerator Supplies the record id. Injected for testability.
 * @param window The permitted check-in hours.
 */
class MarkAttendanceUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val attendanceRepository: AttendanceRepository,
    private val locationTracker: LocationTracker,
    private val geofenceEvaluator: GeofenceEvaluator,
    private val timeProvider: TimeProvider,
    private val idGenerator: IdGenerator,
    private val window: AttendanceWindow = AttendanceWindow.Default,
) {

    /**
     * Runs all five gates and, if every one passes, writes the record.
     *
     * @param timeoutMillis How long to wait for the fresh fix before giving
     *   up with [AppError.Location.Timeout].
     * @return The written [AttendanceRecord], or the **first** gate that
     *   refused. Never throws.
     */
    suspend operator fun invoke(
        timeoutMillis: Long = LocationTracker.DEFAULT_FIX_TIMEOUT_MILLIS,
    ): Outcome<AttendanceRecord> {
        // ── Gate 1: the clock ───────────────────────────────────────────
        if (!window.contains(timeProvider.localTime())) {
            return Outcome.Failure(AppError.Attendance.WindowClosed())
        }

        // ── Gate 2: an office must exist ────────────────────────────────
        // `observe().first()` takes the current value from the flow and stops
        // listening. Two failure shapes are possible here and they mean
        // different things: the read itself failed, or it succeeded and told
        // us there is no anchor.
        val anchor = when (val anchorOutcome = officeAnchorRepository.observe().first()) {
            is Outcome.Failure -> return Outcome.Failure(anchorOutcome.error)
            is Outcome.Success -> anchorOutcome.value
                ?: return Outcome.Failure(AppError.Attendance.OfficeNotConfigured())
        }

        // ── Gate 3: not already marked today ────────────────────────────
        when (val existing = attendanceRepository.findRecordFor(timeProvider.localDate())) {
            is Outcome.Failure -> return Outcome.Failure(existing.error)
            is Outcome.Success -> existing.value?.let {
                return Outcome.Failure(AppError.Attendance.AlreadyMarked(it.markedAtEpochMillis))
            }
        }

        // ── Gates 4 and 5: where is the user, really? ───────────────────
        // Only now is a GPS acquisition worth paying for.
        return locationTracker.currentFix(timeoutMillis).flatMap { fix ->
            // No `previousStatus` is passed, so no hysteresis applies: the
            // decision is judged at the true 50 m fence with no forgiveness.
            // Hysteresis smooths the *display*, never the *decision*.
            val reading = geofenceEvaluator.evaluate(anchor = anchor, fix = fix)

            when {
                // Gate 4 - the fix must be trustworthy before its distance
                // means anything. Checked first: "you are 12 m away, +/-90 m"
                // is not evidence of being inside.
                !reading.isConfident -> Outcome.Failure(
                    AppError.Location.InsufficientAccuracy(
                        reportedAccuracyMeters = fix.accuracyMeters,
                        requiredAccuracyMeters = reading.radiusMeters.toFloat(),
                    ),
                )

                // Gate 5 - the actual perimeter rule the brief asks for.
                !reading.status.isInside -> Outcome.Failure(
                    AppError.Attendance.OutsideGeofence(
                        distanceMeters = reading.distanceMeters,
                        radiusMeters = reading.radiusMeters,
                    ),
                )

                // All five gates passed. Freeze the evidence into a record.
                // Distance and accuracy are stored, not just the timestamp,
                // so the trail stays meaningful after the office moves.
                else -> attendanceRepository.append(
                    AttendanceRecord(
                        id = idGenerator.newId(),
                        markedAtEpochMillis = timeProvider.nowEpochMillis(),
                        point = fix.point,
                        distanceMeters = reading.distanceMeters,
                        accuracyMeters = fix.accuracyMeters,
                        anchorLabel = anchor.label,
                    ),
                )
            }
        }
    }
}
