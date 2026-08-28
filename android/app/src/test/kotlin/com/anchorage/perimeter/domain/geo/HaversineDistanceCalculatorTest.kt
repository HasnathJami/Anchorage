package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * The arithmetic that the entire geofence rests on, pinned against
 * independently computed reference values.
 */
class HaversineDistanceCalculatorTest {

    private val calculator = HaversineDistanceCalculator

    @Test
    fun `distance between identical points is exactly zero`() {
        val point = GeoPoint(23.780887, 90.414391)

        assertThat(calculator.distanceMeters(point, point)).isEqualTo(0.0)
    }

    @Test
    fun `identical points do not produce NaN through floating point drift`() {
        // asin(sqrt(h)) is undefined for h > 1; the min() clamp exists for this.
        val point = GeoPoint(-89.999999, 179.999999)

        assertThat(calculator.distanceMeters(point, point).isNaN()).isFalse()
    }

    @Test
    fun `one degree of latitude is about 111 kilometres`() {
        val from = GeoPoint(0.0, 0.0)
        val to = GeoPoint(1.0, 0.0)

        // Mean-radius great-circle value: 111194.9 m.
        assertThat(calculator.distanceMeters(from, to)).isWithin(2.0).of(111_194.9)
    }

    @Test
    fun `short northward offset matches the metres-per-degree approximation`() {
        val from = GeoPoint(23.780887, 90.414391)
        // 0.00045 deg latitude is very close to 50 m at any longitude.
        val to = GeoPoint(23.780887 + 0.00045, 90.414391)

        assertThat(calculator.distanceMeters(from, to)).isWithin(0.5).of(50.04)
    }

    @Test
    fun `distance is symmetric`() {
        val a = GeoPoint(23.780887, 90.414391)
        val b = GeoPoint(23.795, 90.401)

        assertThat(calculator.distanceMeters(a, b)).isWithin(1e-9).of(calculator.distanceMeters(b, a))
    }

    @Test
    fun `handles the antimeridian without exploding`() {
        val west = GeoPoint(0.0, 179.999)
        val east = GeoPoint(0.0, -179.999)

        // Two thousandths of a degree apart across the seam, about 222 m.
        assertThat(calculator.distanceMeters(west, east)).isWithin(1.0).of(222.4)
    }

    @Test
    fun `poles are the expected half-circumference apart`() {
        val north = GeoPoint(90.0, 0.0)
        val south = GeoPoint(-90.0, 0.0)

        assertThat(calculator.distanceMeters(north, south)).isWithin(1.0).of(20_015_114.4)
    }
}
