package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.LocationFix
import kotlinx.coroutines.flow.Flow

/**
 * The domain's view of the positioning stack.
 *
 * Note the return types: a stream of [Outcome] rather than a stream that
 * throws. A dropped GPS signal is an expected, recoverable event in this
 * product - modelling it as an exception would tear down the collector and
 * force the UI to re-subscribe, losing the geofence hysteresis state.
 */
interface LocationTracker {

    /**
     * Continuous updates until the collector cancels.
     *
     * @param intervalMillis desired cadence; the platform may deliver slower.
     */
    fun stream(intervalMillis: Long = DEFAULT_INTERVAL_MILLIS): Flow<Outcome<LocationFix>>

    /**
     * A single, best-effort high-accuracy fix - used when anchoring the office.
     *
     * @param timeoutMillis how long to wait before giving up with
     *   [com.anchorage.perimeter.core.common.error.AppError.Location.Timeout].
     */
    suspend fun currentFix(timeoutMillis: Long = DEFAULT_FIX_TIMEOUT_MILLIS): Outcome<LocationFix>

    companion object {
        const val DEFAULT_INTERVAL_MILLIS = 2_000L
        const val DEFAULT_FIX_TIMEOUT_MILLIS = 15_000L
    }
}
