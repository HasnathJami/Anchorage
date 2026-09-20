package com.anchorage.perimeter.domain.model

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.GeofenceReading

/**
 * The complete answer to one question: **"what may the user do right now?"**
 *
 * This is the most important type in the Android app. Read it and you know
 * what the attendance screen can possibly show.
 *
 * ## Where it comes from
 *
 * ```
 * OfficeAnchorRepository ─┐
 * LocationTracker ────────┼──► ObserveAttendanceStatusUseCase ──► AttendanceStatus
 * AttendanceRepository ───┘                                             │
 *                                                                       ▼
 *                                              AttendanceViewModel maps it to pixels
 * ```
 *
 * Three live sources are fused into one value, recomputed every time any of
 * them changes (roughly every two seconds, because that is the GPS interval).
 *
 * ## Why the decision lives here and not in the ViewModel
 *
 * The ViewModel does not re-derive any of this — it only maps it onto pixels.
 * Keeping the rule here means two things:
 *
 * 1. It is covered by fast JVM tests, with no Android device involved.
 * 2. It can never drift apart from what
 *    [com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase] will
 *    actually allow. The button's enabled state and the enforcement read the
 *    *same* expression — see [canMarkAttendance].
 *
 * @property anchor The saved office, or `null` if the user has not set one
 *   yet. When this is `null` the screen shows the "set your office" empty
 *   state.
 * @property reading The current distance measurement and inside/outside
 *   verdict, or `null` when there is nothing to measure yet (no anchor, or no
 *   GPS fix has arrived).
 * @property locationError The most recent positioning problem, if any — a
 *   denied permission, a disabled location toggle, a timeout. Drives the
 *   banner at the top of the screen.
 * @property storageError A failure reading the saved anchor from disk. Rare,
 *   and separate from [locationError] because the remedy is different.
 * @property todayRecord Today's check-in, if the user has already marked
 *   attendance. Non-null means the button is spent for the day.
 * @property window The permitted check-in hours. See [AttendanceWindow].
 * @property isWindowOpen Whether the clock is currently inside [window].
 *   Recomputed on every emission, so a screen left open across the closing
 *   time updates by itself.
 * @property radiusMeters The size of the fence being enforced, so the copy
 *   under the dial ("move within 50 metres") reads the *same* number the
 *   decision uses rather than a hard-coded duplicate.
 * @property lastFix The position this status was measured from, if any.
 *   Carried forward across restarts — see the note on the property.
 */
data class AttendanceStatus(
    val anchor: OfficeAnchor?,
    val reading: GeofenceReading?,
    val locationError: AppError.Location?,
    val storageError: AppError.Storage?,
    val todayRecord: AttendanceRecord?,
    val window: AttendanceWindow,
    val isWindowOpen: Boolean,
    val radiusMeters: Double = GeofencePolicy.DEFAULT_RADIUS_METERS,
    /**
     * The position this status was measured from, if any.
     *
     * Exposed so a *restarted* observation can pick up where the last one
     * left off. The GPS stream is torn down whenever the screen leaves the
     * foreground — that is what stops the battery drain — and a fresh one
     * starts with nothing carried forward. Without this, every return to the
     * screen blanked the dial back to `--` until a satellite next answered.
     * Handing the last fix back in means the distance is on screen in the
     * first frame.
     */
    val lastFix: LocationFix? = null,
) {

    /** True once the user has saved an office. Gates the whole screen. */
    val isOfficeConfigured: Boolean get() = anchor != null

    /** True when today's check-in has already been recorded. */
    val isAlreadyMarkedToday: Boolean get() = todayRecord != null

    /**
     * Every gate the check-in must pass, in one expression, in the same order
     * [com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase] enforces
     * them:
     *
     * 1. An office has been set.
     * 2. Attendance has not already been marked today.
     * 3. The clock is inside the permitted window.
     * 4. The user is inside the fence, on a fix accurate enough to believe.
     *
     * If this says `true`, the use case will not reject on a rule the user
     * could have seen coming. (It can still reject — the user may walk out of
     * the fence between render and tap — which is exactly why the use case
     * re-validates rather than trusting the button.)
     */
    val canMarkAttendance: Boolean
        get() = isOfficeConfigured &&
            !isAlreadyMarkedToday &&
            isWindowOpen &&
            reading?.allowsCheckIn == true

    companion object {
        /**
         * The blank state the screen starts in, before any source has
         * reported: no office, no position, nothing marked, window closed.
         *
         * @param window The check-in hours to report while empty.
         */
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
