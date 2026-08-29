package com.anchorage.perimeter.domain.model

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.GeofenceReading

/**
 * The single, complete answer to "what may the user do right now?".
 *
 * The ViewModel does not re-derive any of this; it only maps it onto pixels.
 * Keeping the decision here means the rule is covered by fast JVM tests and
 * can never drift between the button's enabled state and what
 * `MarkAttendanceUseCase` will actually allow.
 */
data class AttendanceStatus(
    val anchor: OfficeAnchor?,
    val reading: GeofenceReading?,
    val locationError: AppError.Location?,
    val storageError: AppError.Storage?,
    val todayRecord: AttendanceRecord?,
    val window: AttendanceWindow,
    val isWindowOpen: Boolean,
    /** The fence being enforced, so the UI never has to guess at it. */
    val radiusMeters: Double = GeofencePolicy.DEFAULT_RADIUS_METERS,
    /**
     * The position this status was measured from, if any.
     *
     * Exposed so a *restarted* observation can pick up where the last one left
     * off. The stream is torn down whenever the screen leaves the foreground -
     * that is what stops the GPS - and a fresh one starts with nothing carried
     * forward, so without this every return to the screen blanked the dial
     * back to `--` until a satellite next answered. Handing the last fix back
     * in means the distance is on screen in the first frame.
     */
    val lastFix: LocationFix? = null,
) {
    val isOfficeConfigured: Boolean get() = anchor != null

    val isAlreadyMarkedToday: Boolean get() = todayRecord != null

    /**
     * Every gate in one expression, in the same order the use case enforces
     * them. If this says `true`, `MarkAttendanceUseCase` will not reject on a
     * rule the user could have seen coming.
     */
    val canMarkAttendance: Boolean
        get() = isOfficeConfigured &&
            !isAlreadyMarkedToday &&
            isWindowOpen &&
            reading?.allowsCheckIn == true

    companion object {
        fun initial(window: AttendanceWindow = AttendanceWindow.Default) = AttendanceStatus(
            anchor = null,
            reading = null,
            locationError = null,
            storageError = null,
            todayRecord = null,
            window = window,
            isWindowOpen = false,
            lastFix = null,
        )
    }
}
