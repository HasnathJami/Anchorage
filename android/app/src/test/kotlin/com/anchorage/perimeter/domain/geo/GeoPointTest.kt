package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.Assert.assertThrows

/** Illegal coordinates must be impossible to construct, not merely discouraged. */
class GeoPointTest {

    @Test
    fun `accepts coordinates on the boundary`() {
        assertThat(GeoPoint(90.0, 180.0)).isNotNull()
        assertThat(GeoPoint(-90.0, -180.0)).isNotNull()
    }

    @Test
    fun `rejects latitude above ninety`() {
        assertThrows(IllegalArgumentException::class.java) { GeoPoint(90.1, 0.0) }
    }

    @Test
    fun `rejects latitude below minus ninety`() {
        assertThrows(IllegalArgumentException::class.java) { GeoPoint(-90.1, 0.0) }
    }

    @Test
    fun `rejects longitude outside the meridian range`() {
        assertThrows(IllegalArgumentException::class.java) { GeoPoint(0.0, 180.1) }
        assertThrows(IllegalArgumentException::class.java) { GeoPoint(0.0, -180.1) }
    }

    @Test
    fun `rejects NaN coordinates`() {
        assertThrows(IllegalArgumentException::class.java) { GeoPoint(Double.NaN, 0.0) }
    }
}
