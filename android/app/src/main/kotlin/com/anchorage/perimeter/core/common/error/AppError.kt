package com.anchorage.perimeter.core.common.error

/**
 * Every way this app can fail, listed in one place.
 *
 * This is the companion to [com.anchorage.perimeter.core.common.outcome.Outcome]:
 * an `Outcome.Failure` always carries one of these. Read this file and you
 * know the complete set of things that can go wrong.
 *
 * ## Two rules make this valuable rather than ceremonial
 *
 * **1. It is exhaustive.** Because it is a sealed hierarchy, the compiler
 * forces every `when` in the presentation layer to handle every branch. Add a
 * new failure here and the app *stops compiling* until someone decides what
 * the user sees. A new failure can never silently render as a blank screen.
 *
 * **2. It is framework-free.** Nothing in this file mentions Android, Play
 * Services or SQL. Data-layer adapters translate platform exceptions into
 * these cases at the boundary - that is why the domain and the ViewModels
 * stay unit-testable on a plain JVM, with no emulator and no Robolectric.
 *
 * ## The rule for adding a case
 *
 * **Every error case must map to a different remedy.** If two cases would
 * render the same message and the same button, they should be one case.
 * [Location.PermissionDenied] and [Location.PermissionPermanentlyDenied] are
 * separate because one offers the system dialog and the other can only offer
 * Settings. That is a real difference to the user; "read failed" versus
 * "read failed differently" is not.
 */
sealed interface AppError {

    /**
     * The original exception, where one exists.
     *
     * Kept for logging and debugging only - it is **never** shown to the
     * user. A stack trace is not a remedy.
     */
    val cause: Throwable?

    /**
     * Everything that can go wrong while asking the device where it is.
     *
     * Each case maps to a *distinct* recovery affordance in the UI, which is
     * the whole reason they are modelled separately instead of as one
     * `LocationFailed`.
     */
    sealed interface Location : AppError {

        /**
         * The user denied the location permission, but can still be asked
         * again.
         *
         * Remedy: show the system permission dialog.
         */
        data class PermissionDenied(
            override val cause: Throwable? = null,
        ) : Location

        /**
         * The user refused twice, or a device policy blocks the grant. The
         * system dialog will no longer appear at all.
         *
         * Remedy: deep-link into the app's Settings page. This is the only
         * route out, which is exactly why it is a separate case from
         * [PermissionDenied].
         */
        data class PermissionPermanentlyDenied(
            override val cause: Throwable? = null,
        ) : Location

        /**
         * Permission was granted, but the device's location toggle is off
         * system-wide.
         *
         * Remedy: offer the location settings screen. Asking for permission
         * again would achieve nothing - it is already granted.
         */
        data class ServicesDisabled(
            override val cause: Throwable? = null,
        ) : Location

        /**
         * The hardware reported no usable fix - a tunnel, a basement,
         * airplane mode.
         *
         * Remedy: none, and that is the point. The condition is momentary and
         * the stream recovers by itself, so the attendance screen deliberately
         * raises **no banner** for it; the dial simply holds the last known
         * distance. The office picker does show one, because it needs a
         * position to centre the map on, so there a Retry button actually
         * does something.
         */
        data class PositionUnavailable(
            override val cause: Throwable? = null,
        ) : Location

        /**
         * No fix arrived within the deadline the use case was willing to
         * wait.
         *
         * @property waitedMillis How long was allowed, so the message can say
         *   "no fix in 15 seconds" rather than something vague.
         */
        data class Timeout(
            val waitedMillis: Long,
            override val cause: Throwable? = null,
        ) : Location

        /**
         * A fix arrived, but its error radius is so large that trusting it
         * would be dishonest - anchoring a 50 m geofence to a +/-40 m fix,
         * for instance.
         *
         * Remedy: tell the user to step outside and wait. Both numbers are
         * carried so the UI can explain itself concretely.
         *
         * @property reportedAccuracyMeters What the fix actually claimed.
         * @property requiredAccuracyMeters What the policy demanded.
         */
        data class InsufficientAccuracy(
            val reportedAccuracyMeters: Float,
            val requiredAccuracyMeters: Float,
            override val cause: Throwable? = null,
        ) : Location
    }

    /**
     * Fetching map imagery for the office picker.
     *
     * Separate from [Location] because the remedies have nothing in common: a
     * missing tile is a *network* problem the user fixes by reconnecting,
     * while a missing fix is a *positioning* problem they fix by stepping
     * outside. Collapsing them would offer the wrong advice.
     *
     * None of these is fatal to the screen. The map degrades to a plain grid
     * and the user can still place a pin, because a picker that refuses to
     * work offline is worse than one that works without pretty pictures.
     */
    sealed interface MapTiles : AppError {

        /** No usable network route to the tile server. */
        data class Offline(override val cause: Throwable? = null) : MapTiles

        /**
         * The request left but nothing came back in time.
         *
         * @property waitedMillis How long was allowed.
         */
        data class Timeout(
            val waitedMillis: Long,
            override val cause: Throwable? = null,
        ) : MapTiles

        /**
         * The server answered, but not with a tile.
         *
         * @property statusCode The HTTP status returned.
         */
        data class ServerRejected(
            val statusCode: Int,
            override val cause: Throwable? = null,
        ) : MapTiles
    }

    /**
     * Local persistence failures - DataStore (the office anchor) or Room (the
     * attendance history).
     */
    sealed interface Storage : AppError {

        /** Could not read what was saved. */
        data class ReadFailed(override val cause: Throwable? = null) : Storage

        /** Could not save. The user's action did not take effect. */
        data class WriteFailed(override val cause: Throwable? = null) : Storage

        /**
         * What was read back was not valid - a truncated write, or a value
         * from an older schema.
         *
         * @property detail What was wrong, for the log.
         */
        data class Corrupted(
            val detail: String,
            override val cause: Throwable? = null,
        ) : Storage
    }

    /**
     * The business rules refused the action.
     *
     * These are **not** technical faults. Nothing is broken; the user is
     * simply not allowed to check in right now, and the UI should say so
     * calmly rather than as an error.
     */
    sealed interface Attendance : AppError {

        /** No office anchor has been captured yet. Remedy: set one. */
        data class OfficeNotConfigured(override val cause: Throwable? = null) : Attendance

        /**
         * The user is outside the permitted radius.
         *
         * @property distanceMeters How far out they actually are.
         * @property radiusMeters The fence they needed to be inside, so the
         *   message can say "you are 120 m away, you need to be within 50 m".
         */
        data class OutsideGeofence(
            val distanceMeters: Double,
            val radiusMeters: Double,
            override val cause: Throwable? = null,
        ) : Attendance

        /**
         * The clock is outside the daily check-in window. Remedy: come back
         * during the window.
         */
        data class WindowClosed(override val cause: Throwable? = null) : Attendance

        /**
         * Attendance was already recorded for the current day.
         *
         * @property markedAtEpochMillis When it was marked, so the message
         *   can say "already marked at 9:14 AM".
         */
        data class AlreadyMarked(
            val markedAtEpochMillis: Long,
            override val cause: Throwable? = null,
        ) : Attendance
    }

    /**
     * The escape hatch, for a throwable nobody anticipated.
     *
     * Its existence is deliberate. An adapter that meets a genuinely unknown
     * exception must still return a *typed* failure rather than let the
     * exception escape and kill the process. Every adapter in this app ends
     * its `catch` chain here.
     *
     * @property detail A short description for the log.
     */
    data class Unexpected(
        val detail: String? = null,
        override val cause: Throwable? = null,
    ) : AppError
}
