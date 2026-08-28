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
 * "Mark Attendance": the authoritative, system-of-record decision.
 *
 * Two design choices deserve justification.
 *
 * **It re-validates everything.** The button is only enabled when
 * [com.anchorage.perimeter.domain.model.AttendanceStatus.canMarkAttendance]
 * is true, so re-checking looks redundant - but a disabled button is a UI
 * affordance, not an enforcement boundary. Between render and tap the user can
 * walk out of the fence, the clock can cross 10:30, or a second device can
 * record the day. The use case is the only place the rule is actually
 * enforced.
 *
 * **It takes a fresh fix.** Trusting the streamed position would let a stale
 * (or paused-in-background) reading authorise a check-in from anywhere. One
 * deliberate round-trip to the positioning stack costs a second and removes
 * that entire class of bug.
 *
 * Failure ordering is intentional: cheap, certain rejections (window, missing
 * anchor, duplicate) run before the expensive GPS acquisition, so a user
 * checking in at 4 p.m. is told why instantly instead of watching a spinner.
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

    suspend operator fun invoke(
        timeoutMillis: Long = LocationTracker.DEFAULT_FIX_TIMEOUT_MILLIS,
    ): Outcome<AttendanceRecord> {
        if (!window.contains(timeProvider.localTime())) {
            return Outcome.Failure(AppError.Attendance.WindowClosed())
        }

        val anchor = when (val anchorOutcome = officeAnchorRepository.observe().first()) {
            is Outcome.Failure -> return Outcome.Failure(anchorOutcome.error)
            is Outcome.Success -> anchorOutcome.value
                ?: return Outcome.Failure(AppError.Attendance.OfficeNotConfigured())
        }

        when (val existing = attendanceRepository.findRecordFor(timeProvider.localDate())) {
            is Outcome.Failure -> return Outcome.Failure(existing.error)
            is Outcome.Success -> existing.value?.let {
                return Outcome.Failure(AppError.Attendance.AlreadyMarked(it.markedAtEpochMillis))
            }
        }

        return locationTracker.currentFix(timeoutMillis).flatMap { fix ->
            val reading = geofenceEvaluator.evaluate(anchor = anchor, fix = fix)

            when {
                !reading.isConfident -> Outcome.Failure(
                    AppError.Location.InsufficientAccuracy(
                        reportedAccuracyMeters = fix.accuracyMeters,
                        requiredAccuracyMeters = reading.radiusMeters.toFloat(),
                    ),
                )

                !reading.status.isInside -> Outcome.Failure(
                    AppError.Attendance.OutsideGeofence(
                        distanceMeters = reading.distanceMeters,
                        radiusMeters = reading.radiusMeters,
                    ),
                )

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
