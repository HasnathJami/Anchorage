package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Haversine great-circle distance on a spherical Earth.
 *
 * Why implement it instead of calling `Location.distanceBetween`?
 *
 *  * `android.location.Location` is a framework class, so using it would drag
 *    the Android SDK into the domain and force every geofence test onto an
 *    emulator or Robolectric.
 *  * Haversine's error against Vincenty is well under 0.3 % - centimetres at
 *    the 50 m scale this app cares about - so the trade is free.
 *
 * The implementation uses the numerically stable `asin(sqrt(h))` form rather
 * than `atan2`, which avoids catastrophic cancellation for the very short
 * distances (metres) that dominate this use case. `min(1.0, ...)` guards the
 * one real hazard: floating-point drift pushing the argument fractionally
 * above 1 and turning `asin` into NaN for two identical points.
 */
object HaversineDistanceCalculator : DistanceCalculator {

    /** IUGG mean Earth radius in metres. */
    private const val EARTH_MEAN_RADIUS_METERS = 6_371_008.8

    override fun distanceMeters(from: GeoPoint, to: GeoPoint): Double {
        val lat1 = Math.toRadians(from.latitude)
        val lat2 = Math.toRadians(to.latitude)
        val deltaLat = lat2 - lat1
        val deltaLon = Math.toRadians(to.longitude - from.longitude)

        val sinHalfDeltaLat = sin(deltaLat / 2.0)
        val sinHalfDeltaLon = sin(deltaLon / 2.0)

        val h = sinHalfDeltaLat * sinHalfDeltaLat +
            cos(lat1) * cos(lat2) * sinHalfDeltaLon * sinHalfDeltaLon

        return 2.0 * EARTH_MEAN_RADIUS_METERS * asin(min(1.0, sqrt(h)))
    }
}
