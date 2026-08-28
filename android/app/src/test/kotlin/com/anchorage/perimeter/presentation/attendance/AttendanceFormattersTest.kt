package com.anchorage.perimeter.presentation.attendance

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.time.ZoneId
import java.util.Locale

class AttendanceFormattersTest {

    private val locale = Locale.US
    private val dhaka: ZoneId = ZoneId.of("Asia/Dhaka")

    @Test
    fun `sub-kilometre distances are whole metres`() {
        assertThat(AttendanceFormatters.distance(0.0, locale)).isEqualTo("0m")
        assertThat(AttendanceFormatters.distance(12.4, locale)).isEqualTo("12m")
        assertThat(AttendanceFormatters.distance(119.6, locale)).isEqualTo("120m")
        assertThat(AttendanceFormatters.distance(999.4, locale)).isEqualTo("999m")
    }

    @Test
    fun `a kilometre and beyond switches unit`() {
        assertThat(AttendanceFormatters.distance(1_000.0, locale)).isEqualTo("1.0 km")
        assertThat(AttendanceFormatters.distance(1_449.0, locale)).isEqualTo("1.4 km")
    }

    @Test
    fun `accuracy keeps one decimal only where it means something`() {
        assertThat(AttendanceFormatters.accuracy(4.5f, locale)).isEqualTo("4.5 m")
        assertThat(AttendanceFormatters.accuracy(42.4f, locale)).isEqualTo("42 m")
    }

    @Test
    fun `an unknown accuracy is named rather than printed as a huge number`() {
        assertThat(AttendanceFormatters.accuracy(Float.MAX_VALUE, locale)).isEqualTo("unknown")
    }

    @Test
    fun `coordinates are trimmed to four decimals`() {
        assertThat(AttendanceFormatters.coordinate(23.780887, locale)).isEqualTo("23.7809")
        assertThat(AttendanceFormatters.coordinate(-74.0060151, locale)).isEqualTo("-74.0060")
    }

    @Test
    fun `clock time renders in the supplied zone`() {
        // 03:30 UTC is 09:30 in Dhaka.
        val epoch = java.time.Instant.parse("2026-08-28T03:30:00Z").toEpochMilli()

        assertThat(AttendanceFormatters.clockTime(epoch, dhaka, locale)).isEqualTo("09:30 AM")
    }

    @Test
    fun `calendar date renders in the supplied zone`() {
        // 20:00 UTC on the 27th is already the 28th in Dhaka.
        val epoch = java.time.Instant.parse("2026-08-27T20:00:00Z").toEpochMilli()

        assertThat(AttendanceFormatters.calendarDate(epoch, dhaka, locale)).isEqualTo("28 Aug 2026")
    }
}
