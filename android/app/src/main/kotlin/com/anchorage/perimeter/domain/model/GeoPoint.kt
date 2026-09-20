package com.anchorage.perimeter.domain.model

/**
 * A single point on the surface of the Earth: a latitude and a longitude.
 *
 * These are the same two numbers you would paste into Google Maps.
 * `GeoPoint(23.8103, 90.4125)` is the centre of Dhaka.
 *
 * ## Where this is used
 *
 * Every geographic value in the app is built out of this one type:
 *
 * - [OfficeAnchor.point] — where the office is.
 * - [LocationFix.point] — where the phone currently is.
 * - Both ends of every distance calculation.
 *
 * ## Why the constructor validates
 *
 * A latitude of 500 is not a place. By checking in the constructor, an invalid
 * coordinate can never exist *anywhere* in the system, so no calculation
 * further downstream has to defend against one. This is the
 * "make illegal states unrepresentable" principle applied at the cheapest
 * possible place — one check, at the only door into the type.
 *
 * The trade-off: constructing an out-of-range point throws
 * [IllegalArgumentException]. That is intentional. It signals a programming
 * mistake, not a runtime condition a user can cause, so it is *not* part of
 * the [com.anchorage.perimeter.core.common.error.AppError] taxonomy.
 *
 * @property latitude Degrees north of the equator. Negative is south.
 *   Valid range is [MIN_LATITUDE] to [MAX_LATITUDE].
 * @property longitude Degrees east of the Greenwich meridian. Negative is
 *   west. Valid range is [MIN_LONGITUDE] to [MAX_LONGITUDE].
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
        // NaN slips past the range checks above, because every comparison
        // involving NaN is false — including the ones `in` is built from.
        require(!latitude.isNaN() && !longitude.isNaN()) { "coordinates must be finite numbers" }
    }

    companion object {
        /** The South Pole. */
        const val MIN_LATITUDE = -90.0

        /** The North Pole. */
        const val MAX_LATITUDE = 90.0

        /** The anti-meridian, going west. */
        const val MIN_LONGITUDE = -180.0

        /** The anti-meridian, going east. */
        const val MAX_LONGITUDE = 180.0
    }
}
