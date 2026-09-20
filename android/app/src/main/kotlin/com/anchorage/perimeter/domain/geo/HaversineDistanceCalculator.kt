package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Measures the distance between two coordinates using the **haversine
 * formula**.
 *
 * ## What the haversine formula is, in plain words
 *
 * You cannot use Pythagoras on latitude and longitude. They are angles on a
 * sphere, not distances on a flat sheet — one degree of longitude is 111 km
 * at the equator and zero at the pole. The haversine formula is the standard
 * way to get the *great-circle* distance: the length of the shortest arc over
 * the surface of a sphere, which is what "as the crow flies" actually means.
 *
 * You do not need to follow the trigonometry to work on this app. What
 * matters is: two [GeoPoint]s in, metres out, accurate to well under a metre
 * at the scale this app cares about.
 *
 * ## Why implement it instead of calling `Location.distanceBetween`?
 *
 * - `android.location.Location` is a framework class, so using it would drag
 *   the Android SDK into the domain layer and force every geofence test onto
 *   an emulator or Robolectric. The architecture test would reject it, and
 *   rightly.
 * - Haversine's error against the more exact Vincenty formula is well under
 *   0.3% — centimetres at the 50 m scale of this geofence — so the trade
 *   costs nothing real.
 *
 * ## Two numerical details worth keeping
 *
 * The implementation uses the numerically stable `asin(sqrt(h))` form rather
 * than the `atan2` variant, which avoids catastrophic cancellation over the
 * very short distances (metres) that dominate this use case.
 *
 * The `min(1.0, ...)` guards the one real hazard: floating-point drift
 * pushing the argument fractionally above 1, which would turn `asin` into
 * `NaN` for two *identical* points. Standing exactly on the anchor is a
 * completely ordinary thing for a user to do.
 */
object HaversineDistanceCalculator : DistanceCalculator {

    /**
     * IUGG mean Earth radius in metres.
     *
     * The Earth is not a sphere, so there is no single correct radius; this
     * is the standard mean that minimises error across the whole surface.
     */
    private const val EARTH_MEAN_RADIUS_METERS = 6_371_008.8

    /**
     * @param from One end of the measurement.
     * @param to The other end.
     * @return Metres between them, along the surface of the Earth.
     */
    override fun distanceMeters(from: GeoPoint, to: GeoPoint): Double {
        // Step 1 - trigonometry works in radians, coordinates arrive in
        // degrees.
        val lat1 = Math.toRadians(from.latitude)
        val lat2 = Math.toRadians(to.latitude)
        val deltaLat = lat2 - lat1
        val deltaLon = Math.toRadians(to.longitude - from.longitude)

        // Step 2 - the "haversine" of each delta. (Haversine of x is
        // sin^2(x/2); the name is short for "half the versed sine".)
        val sinHalfDeltaLat = sin(deltaLat / 2.0)
        val sinHalfDeltaLon = sin(deltaLon / 2.0)

        // Step 3 - combine them. `h` is the haversine of the angle subtended
        // at the centre of the Earth by the two points. The cos(lat1) *
        // cos(lat2) term is what shrinks a degree of longitude as you move
        // away from the equator.
        val h = sinHalfDeltaLat * sinHalfDeltaLat +
            cos(lat1) * cos(lat2) * sinHalfDeltaLon * sinHalfDeltaLon

        // Step 4 - turn that angle back into a surface distance. The min()
        // is the NaN guard described in the class comment.
        return 2.0 * EARTH_MEAN_RADIUS_METERS * asin(min(1.0, sqrt(h)))
    }
}
