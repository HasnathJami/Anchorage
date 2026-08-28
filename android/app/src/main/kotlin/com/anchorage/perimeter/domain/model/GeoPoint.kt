package com.anchorage.perimeter.domain.model

/**
 * A WGS-84 coordinate.
 *
 * Validation lives in the constructor on purpose: an invalid coordinate can
 * never exist anywhere in the system, so no downstream calculation has to
 * defend against one. This is the "make illegal states unrepresentable"
 * principle applied at the cheapest possible place.
 */
data class GeoPoint(
    val latitude: Double,
    val longitude: Double,
) {
    init {
        require(latitude in MIN_LATITUDE..MAX_LATITUDE) {
            "latitude must be within [$MIN_LATITUDE, $MAX_LATITUDE] but was $latitude"
        }
        require(longitude in MIN_LONGITUDE..MAX_LONGITUDE) {
            "longitude must be within [$MIN_LONGITUDE, $MAX_LONGITUDE] but was $longitude"
        }
        require(!latitude.isNaN() && !longitude.isNaN()) { "coordinates must be finite numbers" }
    }

    companion object {
        const val MIN_LATITUDE = -90.0
        const val MAX_LATITUDE = 90.0
        const val MIN_LONGITUDE = -180.0
        const val MAX_LONGITUDE = 180.0
    }
}
