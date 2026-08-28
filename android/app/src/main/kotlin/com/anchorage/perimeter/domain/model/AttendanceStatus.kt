package com.anchorage.perimeter.domain.model

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.domain.policy.AttendanceWindow
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
        )
    }
}
