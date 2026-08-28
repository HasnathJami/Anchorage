package com.anchorage.perimeter.domain.policy

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.Assert.assertThrows
import java.time.LocalTime

class AttendanceWindowTest {

    private val window = AttendanceWindow.Default

    @Test
    fun `default window matches the caption printed in the design`() {
        assertThat(window.format()).isEqualTo("09:00 AM - 10:30 AM")
    }

    @Test
    fun `open exactly at the opening minute`() {
        assertThat(window.contains(LocalTime.of(9, 0))).isTrue()
    }

    @Test
    fun `open exactly at the closing minute`() {
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
