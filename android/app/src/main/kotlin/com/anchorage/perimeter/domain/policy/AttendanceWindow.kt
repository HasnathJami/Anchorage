package com.anchorage.perimeter.domain.policy

import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The daily interval during which a check-in is accepted.
 *
 * The reference design prints "AVAILABLE 09:00 AM - 10:30 AM" under the
 * button, so the window is a real business rule rather than decoration - the
 * app enforces what its own UI promises.
 *
 * Both ends are compared inclusively; a user tapping at exactly 10:30:00 is
 * admitted, because "closes at 10:30" reads to a human as "10:30 still works".
 */
data class AttendanceWindow(
    val opensAt: LocalTime = DEFAULT_OPENS_AT,
    val closesAt: LocalTime = DEFAULT_CLOSES_AT,
) {
    init {
        require(opensAt.isBefore(closesAt)) { "window must open before it closes" }
    }

    fun contains(time: LocalTime): Boolean = !time.isBefore(opensAt) && !time.isAfter(closesAt)

    /** Renders as "09:00 AM - 10:30 AM" for the caption under the button. */
    fun format(locale: Locale = Locale.US): String {
        val formatter = DateTimeFormatter.ofPattern("hh:mm a", locale)
        return "${opensAt.format(formatter)} - ${closesAt.format(formatter)}"
    }

    companion object {
        /**
         * **Currently the whole day**, so the app can be picked up and tried at
         * any hour.
         *
         * The reference design prints `AVAILABLE 09:00 AM - 10:30 AM`, and that
         * is the shape this rule is built for - a real morning check-in window.
         * It is widened here on purpose rather than removed: every gate, every
         * message and every test that enforces it is still in place, and
         * narrowing it again is a one-line change to these two constants.
         *
         * `23:59` rather than midnight because [contains] is inclusive at both
         * ends and the constructor requires the window to open before it
         * closes - a window from `00:00` to `00:00` is not a day, it is an
         * instant.
         */
        val DEFAULT_OPENS_AT: LocalTime = LocalTime.MIDNIGHT
        val DEFAULT_CLOSES_AT: LocalTime = LocalTime.of(23, 59)

        val Default = AttendanceWindow()
    }
}
