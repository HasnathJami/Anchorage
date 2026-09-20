package com.anchorage.perimeter.domain.policy

import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The hours of the day during which checking in is allowed.
 *
 * The reference design prints "AVAILABLE 09:00 AM - 10:30 AM" under the
 * button, so this is a real business rule rather than decoration — the app
 * enforces exactly what its own UI promises, and both read from this one
 * object.
 *
 * ## Inclusive at both ends
 *
 * A user tapping at exactly 10:30:00 is admitted, because "closes at 10:30"
 * reads to a human as "10:30 still works". The alternative — rejecting at
 * 10:30:00.001 — is technically defensible and would feel like a bug.
 *
 * @property opensAt First moment a check-in is accepted.
 * @property closesAt Last moment a check-in is accepted.
 */
data class AttendanceWindow(
    val opensAt: LocalTime = DEFAULT_OPENS_AT,
    val closesAt: LocalTime = DEFAULT_CLOSES_AT,
) {
    init {
        require(opensAt.isBefore(closesAt)) { "window must open before it closes" }
    }

    /**
     * Whether [time] falls inside the window.
     *
     * @param time The local wall-clock time to test, normally supplied by
     *   [com.anchorage.perimeter.domain.port.TimeProvider] so tests can pin
     *   it to any hour.
     * @return `true` when a check-in would be allowed at [time].
     */
    fun contains(time: LocalTime): Boolean = !time.isBefore(opensAt) && !time.isAfter(closesAt)

    /**
     * Renders the window as "09:00 AM - 10:30 AM" for the caption under the
     * check-in button.
     *
     * @param locale Controls the AM/PM wording and digit shapes.
     */
    fun format(locale: Locale = Locale.US): String {
        val formatter = DateTimeFormatter.ofPattern("hh:mm a", locale)
        return "${opensAt.format(formatter)} - ${closesAt.format(formatter)}"
    }

    companion object {
        /**
         * **Currently the whole day**, so the app can be picked up and tried
         * at any hour.
         *
         * The reference design prints `AVAILABLE 09:00 AM - 10:30 AM`, and
         * that is the shape this rule is built for — a real morning check-in
         * window. It is widened here on purpose rather than removed: every
         * gate, every message and every test that enforces it is still in
         * place, and narrowing it again is a one-line change to these two
         * constants.
         *
         * Every test that covers the rule builds its own narrow window rather
         * than reading these defaults, so widening it for a demo cannot
         * quietly delete the coverage of the thing it widens.
         *
         * `23:59` rather than midnight because [contains] is inclusive at
         * both ends and the constructor requires the window to open before it
         * closes — a window from `00:00` to `00:00` is not a day, it is an
         * instant.
         */
        val DEFAULT_OPENS_AT: LocalTime = LocalTime.MIDNIGHT

        /** See [DEFAULT_OPENS_AT]. Narrow both together. */
        val DEFAULT_CLOSES_AT: LocalTime = LocalTime.of(23, 59)

        /** The window the app actually runs with. */
        val Default = AttendanceWindow()
    }
}
