package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.math.abs

/**
 * The projection is the one part of the map screen that fails *silently*.
 *
 * A wrong sign or a missing `cos(latitude)` does not crash - it draws the
 * 50 metre perimeter at the wrong size, and a fence that lies about its own
 * radius is worse than no fence at all. Hence a test per property rather than
 * a single smoke test.
 */
class WebMercatorTest {

    @Test
    fun `the origin of the world plane is the north-west corner`() {
        val northWest = WebMercator.toWorldPixel(
            GeoPoint(WebMercator.MAX_LATITUDE, -180.0),
            zoom = 0,
        )

        assertThat(northWest.x).isWithin(TOLERANCE).of(0.0)
        assertThat(northWest.y).isWithin(TOLERANCE).of(0.0)
    }

    @Test
    fun `the equator at the prime meridian sits at the centre of the plane`() {
        val centre = WebMercator.toWorldPixel(GeoPoint(0.0, 0.0), zoom = 1)
        val half = WebMercator.worldSizePixels(1) / 2.0

        assertThat(centre.x).isWithin(TOLERANCE).of(half)
        assertThat(centre.y).isWithin(TOLERANCE).of(half)
    }

    @Test
    fun `a coordinate survives a round trip through the projection`() {
        val points = listOf(
            GeoPoint(23.780887, 90.414391),
            GeoPoint(-33.865143, 151.209900),
            GeoPoint(59.913868, 10.752245),
            GeoPoint(0.0, 0.0),
        )

        points.forEach { original ->
            val restored = WebMercator.toGeoPoint(
                WebMercator.toWorldPixel(original, zoom = 17),
                zoom = 17,
            )

            assertThat(abs(restored.latitude - original.latitude)).isLessThan(1e-6)
            assertThat(abs(restored.longitude - original.longitude)).isLessThan(1e-6)
        }
    }

    @Test
    fun `latitude is clamped at the projection limit rather than diverging`() {
        // Mercator sends the poles to infinity. Clamping is what stops a drag
        // towards the top of the world producing a NaN and a blank map.
        val northPole = WebMercator.toWorldPixel(GeoPoint(90.0, 0.0), zoom = 4)

        assertThat(northPole.y.isFinite()).isTrue()
        assertThat(northPole.y).isWithin(TOLERANCE).of(0.0)
    }

    @Test
    fun `panning past the anti-meridian wraps rather than sticking at 180`() {
        val zoom = 3
        val worldWidth = WebMercator.worldSizePixels(zoom)
        val overshootPixels = 10.0

        val wrapped = WebMercator.toGeoPoint(
            WorldPixel(x = worldWidth + overshootPixels, y = worldWidth / 2.0),
            zoom = zoom,
        )

        // Overshooting the right edge by N pixels must land N pixels in from
        // the *left* edge - the expectation is derived from the same widths
        // rather than eyeballed, so it stays correct at any zoom.
        val degreesPerPixel = 360.0 / worldWidth
        assertThat(wrapped.longitude)
            .isWithin(TOLERANCE)
            .of(-180.0 + overshootPixels * degreesPerPixel)

        assertThat(wrapped.longitude).isGreaterThan(-180.0)
    }

    @Test
    fun `resolution halves with every zoom level`() {
        val coarse = WebMercator.metresPerPixel(latitude = 0.0, zoom = 10)
        val fine = WebMercator.metresPerPixel(latitude = 0.0, zoom = 11)

        assertThat(fine).isWithin(1e-9).of(coarse / 2.0)
    }

    @Test
    fun `resolution shrinks with latitude so the perimeter keeps its true size`() {
        // The bug this guards: dropping cos(latitude) draws an identical circle
        // everywhere, so a 50 m fence in Oslo would cover far more ground than
        // a 50 m fence in Dhaka while claiming the same radius.
        val equator = WebMercator.metresPerPixel(latitude = 0.0, zoom = 17)
        val dhaka = WebMercator.metresPerPixel(latitude = 23.78, zoom = 17)
        val oslo = WebMercator.metresPerPixel(latitude = 59.91, zoom = 17)

        assertThat(dhaka).isLessThan(equator)
        assertThat(oslo).isLessThan(dhaka)
        // cos(60°) is a half, so Oslo's ground resolution is about half the
        // equator's at the same zoom.
        assertThat(oslo / equator).isWithin(0.02).of(0.5)
    }

    @Test
    fun `zoom zero is a single tile and zoom two is sixteen`() {
        assertThat(WebMercator.tileAt(WorldPixel(0.0, 0.0), zoom = 0).gridSize).isEqualTo(1)
        assertThat(WebMercator.tileAt(WorldPixel(0.0, 0.0), zoom = 2).gridSize).isEqualTo(4)
    }

    @Test
    fun `a pixel resolves to the tile that contains it`() {
        val tile = WebMercator.tileAt(WorldPixel(x = 300.0, y = 700.0), zoom = 5)

        assertThat(tile.x).isEqualTo(1) // 300 / 256
        assertThat(tile.y).isEqualTo(2) // 700 / 256
        assertThat(tile.zoom).isEqualTo(5)
    }

    private companion object {
        const val TOLERANCE = 1e-6
    }
}
