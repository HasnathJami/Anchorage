package com.anchorage.perimeter.domain.policy

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.Assert.assertThrows
import java.time.LocalTime

class AttendanceWindowTest {

    /**
     * The reference design's morning window.
     *
     * Declared here rather than taken from [AttendanceWindow.Default], because
     * the shipped default is currently the whole day so the app can be tried at
     * any hour - and a rule about being *outside* a window cannot be tested
     * with one that nothing is outside of. Widening the default must not
     * quietly delete the coverage of the rule it widens.
     */
    private val window = AttendanceWindow(
        opensAt = LocalTime.of(9, 0),
        closesAt = LocalTime.of(10, 30),
    )

    @Test
    fun `the shipped default currently spans the whole day`() {
        assertThat(AttendanceWindow.Default.format()).isEqualTo("12:00 AM - 11:59 PM")
        assertThat(AttendanceWindow.Default.contains(LocalTime.MIDNIGHT)).isTrue()
        assertThat(AttendanceWindow.Default.contains(LocalTime.of(23, 59))).isTrue()
        assertThat(AttendanceWindow.Default.contains(LocalTime.NOON)).isTrue()
    }

    @Test
    fun `a window renders the caption the design prints`() {
        assertThat(window.format()).isEqualTo("09:00 AM - 10:30 AM")
    }

    @Test
    fun `open exactly at the opening minute`() {
        assertThat(window.contains(LocalTime.of(9, 0))).isTrue()
    }

    @Test
    fun `open exactly at the closing minute`() {
        // Inclusive on purpose: "closes at 10:30" reads to a human as
        // "10:30 still works".
        assertThat(window.contains(LocalTime.of(10, 30))).isTrue()
    }

    @Test
    fun `closed one minute early`() {
        assertThat(window.contains(LocalTime.of(8, 59))).isFalse()
    }

    @Test
    fun `closed one second late`() {
        assertThat(window.contains(LocalTime.of(10, 30, 1))).isFalse()
    }

    @Test
    fun `rejects an inverted window`() {
        assertThrows(IllegalArgumentException::class.java) {
            AttendanceWindow(opensAt = LocalTime.of(11, 0), closesAt = LocalTime.of(9, 0))
        }
    }
}
