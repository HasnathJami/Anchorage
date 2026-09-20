package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.LocationFix
import kotlinx.coroutines.flow.Flow

/**
 * The domain's view of "where is this phone?".
 *
 * ## What a "port" is
 *
 * This is an interface the **domain** defines and the **data** layer
 * implements. The arrow points inward: the domain says what it needs, and
 * [com.anchorage.perimeter.data.location.FusedLocationTracker] — which knows
 * about Google Play Services — bends itself to fit. The domain never learns
 * that Play Services exists.
 *
 * That is what makes every use case in this app testable without a device:
 * a test hands over a fake tracker that emits whatever fixes the test needs.
 *
 * ## Why the return types carry Outcome
 *
 * Note that this is a stream of [Outcome], not a stream that throws. A
 * dropped GPS signal is an **expected, recoverable event** in this product,
 * not an exception. Modelling it as a thrown exception would tear down the
 * collector and force the UI to re-subscribe — which would lose the geofence
 * hysteresis state and blank the dial. As a value, it flows through like any
 * other reading.
 */
interface LocationTracker {

    /**
     * Continuous position updates until the collector stops listening.
     *
     * This is what drives the live distance dial. Collection is what starts
     * the GPS; cancelling the collector is what stops it, which is how the
     * app avoids draining the battery behind the home screen.
     *
     * @param intervalMillis The cadence to ask for. The platform may deliver
     *   more slowly — this is a request, not a guarantee.
     * @return A cold [Flow]: nothing happens until something collects it.
     */
    fun stream(intervalMillis: Long = DEFAULT_INTERVAL_MILLIS): Flow<Outcome<LocationFix>>

    /**
     * One single, best-effort, high-accuracy fix.
     *
     * Used at the two moments that must not trust a streamed value: capturing
     * the office anchor, and marking attendance.
     *
     * @param timeoutMillis How long to wait before giving up with
     *   [com.anchorage.perimeter.core.common.error.AppError.Location.Timeout].
     * @return The fix, or a typed failure. Never throws.
     */
    suspend fun currentFix(timeoutMillis: Long = DEFAULT_FIX_TIMEOUT_MILLIS): Outcome<LocationFix>

    companion object {
        /**
         * Two seconds. Fast enough that walking towards the office visibly
         * moves the dial; slow enough not to cook the battery.
         */
        const val DEFAULT_INTERVAL_MILLIS = 2_000L

        /**
         * Fifteen seconds. A cold GPS start indoors genuinely can take this
         * long, and giving up sooner would reject users who are standing in
         * the right place.
         */
        const val DEFAULT_FIX_TIMEOUT_MILLIS = 15_000L
    }
}
