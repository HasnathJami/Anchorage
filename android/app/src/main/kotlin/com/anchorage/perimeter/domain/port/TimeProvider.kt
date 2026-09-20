package com.anchorage.perimeter.domain.port

import java.time.Clock
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * "What time is it?", as something you can inject.
 *
 * ## Why this exists
 *
 * Two of this app's rules are about time:
 *
 * - Check-in is only allowed inside [com.anchorage.perimeter.domain.policy.AttendanceWindow].
 * - Attendance can only be marked once per calendar day.
 *
 * With `System.currentTimeMillis()` sprinkled through the use cases, neither
 * rule could be tested without either sleeping or waiting until 9 a.m. Behind
 * this port, a test pins the clock to any instant it likes and asserts the
 * rule directly, in milliseconds.
 *
 * This is the same idea as [LocationTracker] and [IdGenerator]: anything
 * non-deterministic is a dependency, never a direct call.
 */
interface TimeProvider {

    /** Now, in milliseconds since 1 Jan 1970 UTC. Stamped onto records. */
    fun nowEpochMillis(): Long

    /**
     * The time zone to interpret instants in.
     *
     * Needed because "today" is a *local* idea. A check-in at 06:00 in Dhaka
     * is on a different UTC date than the local one, and the once-per-day
     * rule must follow the user's calendar, not UTC's.
     */
    fun zone(): ZoneId

    /** The current wall-clock time, for the attendance window check. */
    fun localTime(): LocalTime

    /** The current local calendar day, for the once-per-day check. */
    fun localDate(): LocalDate
}

/**
 * The real implementation, used in production.
 *
 * @param clock The system clock. Exposed as a parameter mainly so that a
 *   test can pass `Clock.fixed(...)` if it wants the real class rather than
 *   a fake.
 */
class SystemTimeProvider(
    private val clock: Clock = Clock.systemDefaultZone(),
) : TimeProvider {
    override fun nowEpochMillis(): Long = clock.millis()
    override fun zone(): ZoneId = clock.zone
    override fun localTime(): LocalTime = LocalTime.now(clock)
    override fun localDate(): LocalDate = LocalDate.now(clock)
}
