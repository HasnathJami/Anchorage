package com.anchorage.perimeter.core.common.error

/**
 * The complete, closed taxonomy of failures Anchorage can experience.
 *
 * Two rules make this type valuable rather than ceremonial:
 *
 *  1. **It is exhaustive.** Because it is a sealed hierarchy the compiler
 *     forces every `when` in the presentation layer to handle every branch, so
 *     a newly introduced failure can never silently render as a blank screen.
 *  2. **It is framework-free.** Nothing here mentions Android, Play Services
 *     or SQL. Data-layer adapters translate platform exceptions into these
 *     cases at the boundary, which is exactly why the domain and the
 *     ViewModels stay unit-testable without Robolectric.
 */
sealed interface AppError {

    /** The originating throwable, when one exists. Never surfaced to the user. */
    val cause: Throwable?

    /**
     * Everything that can go wrong while asking the device where it is.
     * Each case maps to a *distinct* recovery affordance in the UI, which is
     * the whole reason they are modelled separately instead of as one
     * `LocationFailed`.
     */
    sealed interface Location : AppError {

        /** User denied the runtime permission but can be asked again. */
        data class PermissionDenied(
            override val cause: Throwable? = null,
        ) : Location

        /**
         * User selected "Don't allow" twice (or a policy blocks the grant):
         * the system dialog will no longer appear, so the only recovery is a
         * deep link into app settings.
         */
        data class PermissionPermanentlyDenied(
            override val cause: Throwable? = null,
        ) : Location

        /** Permission is granted but the device's location toggle is off. */
        data class ServicesDisabled(
            override val cause: Throwable? = null,
        ) : Location

        /** Hardware/driver reported no usable fix (tunnel, airplane mode...). */
        data class PositionUnavailable(
            override val cause: Throwable? = null,
        ) : Location

        /** No fix arrived inside the deadline the use case was willing to wait. */
        data class Timeout(
            val waitedMillis: Long,
            override val cause: Throwable? = null,
        ) : Location

        /**
         * A fix arrived, but its horizontal accuracy is so poor that anchoring
         * an office to it (or admitting someone through a 50 m gate with it)
         * would be dishonest. Carries the numbers so the UI can explain itself.
         */
        data class InsufficientAccuracy(
            val reportedAccuracyMeters: Float,
            val requiredAccuracyMeters: Float,
            override val cause: Throwable? = null,
        ) : Location
    }

    /** Local persistence failures - DataStore or Room. */
    sealed interface Storage : AppError {
        data class ReadFailed(override val cause: Throwable? = null) : Storage
        data class WriteFailed(override val cause: Throwable? = null) : Storage
        data class Corrupted(
            val detail: String,
            override val cause: Throwable? = null,
        ) : Storage
    }

    /** Business rules refused the action; not a technical fault. */
    sealed interface Attendance : AppError {
        /** No office anchor has been captured yet. */
        data class OfficeNotConfigured(override val cause: Throwable? = null) : Attendance

        /** The user is outside the permitted radius. */
        data class OutsideGeofence(
            val distanceMeters: Double,
            val radiusMeters: Double,
            override val cause: Throwable? = null,
        ) : Attendance

        /** Outside the daily check-in window. */
        data class WindowClosed(override val cause: Throwable? = null) : Attendance

        /** Attendance was already recorded for the current day. */
        data class AlreadyMarked(
            val markedAtEpochMillis: Long,
            override val cause: Throwable? = null,
        ) : Attendance
    }

    /**
     * The escape hatch. Its existence is deliberate: an adapter that meets a
     * genuinely unknown throwable must still return a typed failure rather
     * than let the exception escape and kill the process.
     */
    data class Unexpected(
        val detail: String? = null,
        override val cause: Throwable? = null,
    ) : AppError
}
