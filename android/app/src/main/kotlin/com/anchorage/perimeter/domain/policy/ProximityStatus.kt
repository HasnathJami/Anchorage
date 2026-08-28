package com.anchorage.perimeter.domain.policy

/** Which side of the fence the latest trusted fix put the user on. */
enum class ProximityStatus {
    /** Within the fence: check-in is permitted by proximity. */
    INSIDE,

    /** Beyond the fence (or beyond the exit threshold when already inside). */
    OUTSIDE,
    ;

    val isInside: Boolean get() = this == INSIDE
}
