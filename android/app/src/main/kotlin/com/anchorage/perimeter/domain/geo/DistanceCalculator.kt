package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint

/**
 * Port for great-circle distance. Kept as an interface so the geofence rules
 * can be tested against a stub that returns exact, hand-chosen distances -
 * separating "is the arithmetic right?" from "is the policy right?".
 */
fun interface DistanceCalculator {
    /** Great-circle distance between [from] and [to], in metres. */
    fun distanceMeters(from: GeoPoint, to: GeoPoint): Double
}
