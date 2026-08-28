package com.anchorage.perimeter.domain.geo

import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate
import kotlin.math.PI
import kotlin.math.asinh
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.sinh
import kotlin.math.tan

/**
 * The Web Mercator projection, as used by every slippy-map tile scheme.
 *
 * Pure arithmetic with no Android and no networking, so the map screen's
 * hardest part - "which tile is under this finger, and how many pixels is 50
 * metres?" - is unit-testable on the JVM in milliseconds. Getting this wrong
 * does not crash; it silently draws the geofence at the wrong size, which is
 * exactly the kind of bug that survives a demo and fails in the field.
 *
 * Coordinates are expressed in **world pixels**: the whole planet is a square
 * of `TILE_SIZE * 2^zoom` pixels at a given zoom, with (0,0) at the top-left
 * (180°W, ~85°N). A tile is a [TILE_SIZE]-pixel square of that plane.
 */
object WebMercator {

    /** Edge length of one tile, in pixels. The OSM/Google standard. */
    const val TILE_SIZE = 256

    /**
     * The latitude beyond which Mercator diverges.
     *
     * The projection sends the poles to infinity, so every slippy map clamps
     * here and renders a square world instead of an infinitely tall one.
     */
    const val MAX_LATITUDE = 85.05112878

    /** Metres per pixel at the equator, zoom 0. Earth circumference / 256. */
    private const val EQUATORIAL_METRES_PER_PIXEL = 156_543.03392804097

    fun worldSizePixels(zoom: Int): Double = TILE_SIZE.toDouble() * (1 shl zoom)

    fun longitudeToWorldX(longitude: Double, zoom: Int): Double =
        (longitude + 180.0) / 360.0 * worldSizePixels(zoom)

    fun latitudeToWorldY(latitude: Double, zoom: Int): Double {
        val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
        val radians = clamped * PI / 180.0
        // asinh(tan(φ)) is the numerically stable form of ln(tan φ + sec φ);
        // the naive version loses precision near the equator.
        val mercatorY = asinh(tan(radians))
        return (1.0 - mercatorY / PI) / 2.0 * worldSizePixels(zoom)
    }

    fun worldXToLongitude(x: Double, zoom: Int): Double =
        x / worldSizePixels(zoom) * 360.0 - 180.0

    fun worldYToLatitude(y: Double, zoom: Int): Double {
        val mercatorY = (1.0 - 2.0 * y / worldSizePixels(zoom)) * PI
        return atan(sinh(mercatorY)) * 180.0 / PI
    }

    fun toWorldPixel(point: GeoPoint, zoom: Int): WorldPixel = WorldPixel(
        x = longitudeToWorldX(point.longitude, zoom),
        y = latitudeToWorldY(point.latitude, zoom),
    )

    /**
     * Inverse of [toWorldPixel].
     *
     * Longitude is wrapped rather than clamped: dragging the map past the
     * anti-meridian should wrap the world, not pin the pin to 180°. Latitude
     * *is* clamped, because there is nothing past the projection's poles.
     */
    fun toGeoPoint(pixel: WorldPixel, zoom: Int): GeoPoint {
        val world = worldSizePixels(zoom)
        val wrappedX = pixel.x - floor(pixel.x / world) * world
        return GeoPoint(
            latitude = worldYToLatitude(pixel.y.coerceIn(0.0, world), zoom)
                .coerceIn(-MAX_LATITUDE, MAX_LATITUDE),
            longitude = worldXToLongitude(wrappedX, zoom),
        )
    }

    /**
     * Ground resolution at [latitude] and [zoom].
     *
     * This is what converts the domain's 50-metre radius into a circle of the
     * right size on screen. It shrinks with `cos(latitude)` - a 50 m circle is
     * visibly larger in pixels in Oslo than in Dhaka at the same zoom, and
     * ignoring that draws a fence that lies about its own size.
     */
    fun metresPerPixel(latitude: Double, zoom: Int): Double {
        val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
        return EQUATORIAL_METRES_PER_PIXEL * cos(clamped * PI / 180.0) / (1 shl zoom)
    }

    /** The tile containing [pixel]. */
    fun tileAt(pixel: WorldPixel, zoom: Int): TileCoordinate = TileCoordinate(
        x = floor(pixel.x / TILE_SIZE).toInt(),
        y = floor(pixel.y / TILE_SIZE).toInt(),
        zoom = zoom,
    )

    /** Natural log helper kept for readability in tests. */
    internal fun mercatorY(latitudeDegrees: Double): Double =
        ln(tan(PI / 4.0 + latitudeDegrees * PI / 360.0))
}

/** A point on the projected world plane, in pixels, at a specific zoom. */
data class WorldPixel(val x: Double, val y: Double)
