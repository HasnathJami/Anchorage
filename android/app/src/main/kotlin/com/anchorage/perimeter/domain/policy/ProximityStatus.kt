package com.anchorage.perimeter.domain.policy

/**
 * Which side of the office fence the latest trusted fix put the user on.
 *
 * Deliberately just two values. "Nearly inside" is not a state the product
 * has an answer for — the user either may check in or may not.
 */
enum class ProximityStatus {
    /** Within the fence. Check-in is permitted, as far as proximity goes. */
    INSIDE,

    /**
     * Beyond the fence — or, when the user was already inside, beyond the
     * slightly wider *exit* threshold. See
     * [GeofencePolicy.exitHysteresisMeters] for why those differ.
     */
    OUTSIDE,
    ;

    /** Reads better than `== INSIDE` at call sites. */
    val isInside: Boolean get() = this == INSIDE
}
