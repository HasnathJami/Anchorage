package com.anchorage.perimeter.domain.port

import java.time.Clock
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * Injectable clock.
 *
 * `System.currentTimeMillis()` sprinkled through use cases makes the
 * attendance-window and once-per-day rules impossible to test without sleeping
 * or waiting for 9 a.m. Behind this port a test can pin the clock to any
 * instant and assert the rule directly.
 */
interface TimeProvider {
    fun nowEpochMillis(): Long
    fun zone(): ZoneId
    fun localTime(): LocalTime
    fun localDate(): LocalDate
}

/** Production implementation delegating to the system clock. */
class SystemTimeProvider(
    private val clock: Clock = Clock.systemDefaultZone(),
) : TimeProvider {
    override fun nowEpochMillis(): Long = clock.millis()
    override fun zone(): ZoneId = clock.zone
    override fun localTime(): LocalTime = LocalTime.now(clock)
    override fun localDate(): LocalDate = LocalDate.now(clock)
}
