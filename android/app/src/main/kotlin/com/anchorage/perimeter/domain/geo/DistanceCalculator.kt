package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint

/**
 * "How far apart are these two coordinates, in metres?"
 *
 * Kept as an interface with a single method so the geofence rules can be
 * tested against a stub that returns exact, hand-chosen distances. That
 * separates two questions which are much easier to answer apart than
 * together:
 *
 * - *Is the arithmetic right?* → tested against
 *   [HaversineDistanceCalculator] with known city-to-city distances.
 * - *Is the rule right?* → tested against a stub that simply returns 49.0 or
 *   51.0, with no trigonometry in sight.
 *
 * The production implementation is [HaversineDistanceCalculator].
 */
fun interface DistanceCalculator {
    /**
     * Great-circle ("as the crow flies") distance between two points.
     *
     * @param from One end. Order does not matter; the result is symmetric.
     * @param to The other end.
     * @return The distance in metres. Never negative.
     */
    fun distanceMeters(from: GeoPoint, to: GeoPoint): Double
}
