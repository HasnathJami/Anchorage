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
 * The maths behind the map screen: converting between **latitude/longitude**
 * and **pixels on screen**.
 *
 * ## What Web Mercator is
 *
 * Every online map — Google, OSM, Apple — flattens the round Earth onto a
 * square using the same projection, called Web Mercator, and then chops that
 * square into 256x256 pixel images called *tiles*. This object implements
 * that projection so the office picker can answer two questions:
 *
 * - "Which tile image do I need to download for this part of the world?"
 * - "The office geofence is 50 metres — how many pixels wide is that circle
 *   on screen right now?"
 *
 * ## World pixels
 *
 * Coordinates here are expressed in **world pixels**: at a given zoom level
 * the whole planet is one square of `TILE_SIZE * 2^zoom` pixels, with (0,0)
 * at the top-left corner — that is 180 degrees west, about 85 degrees north.
 * Zoom 0 is the entire Earth in a single 256px tile; each zoom level doubles
 * the resolution.
 *
 * ## Why it lives in the domain layer
 *
 * Pure arithmetic, no Android, no networking — so the map screen's hardest
 * part is unit-testable on the JVM in milliseconds. Getting this wrong does
 * not crash: it silently draws the geofence at the wrong size, which is
 * exactly the kind of bug that survives a demo and fails in the field.
 */
object WebMercator {

    /** Edge length of one tile in pixels. The OSM and Google standard. */
    const val TILE_SIZE = 256

    /**
     * The latitude beyond which Mercator diverges (about 85.05 degrees).
     *
     * The projection stretches distances towards the poles and sends the
     * poles themselves to infinity, so every slippy map in the world clamps
     * here and renders a square world instead of an infinitely tall one.
     */
    const val MAX_LATITUDE = 85.05112878

    /** Metres per pixel at the equator at zoom 0: Earth's circumference / 256. */
    private const val EQUATORIAL_METRES_PER_PIXEL = 156_543.03392804097

    /**
     * The width (and height) of the whole world in pixels at [zoom].
     *
     * `1 shl zoom` is `2^zoom` written as a bit shift.
     */
    fun worldSizePixels(zoom: Int): Double = TILE_SIZE.toDouble() * (1 shl zoom)

    /** Longitude is the easy axis: it maps linearly onto x. */
    fun longitudeToWorldX(longitude: Double, zoom: Int): Double =
        (longitude + 180.0) / 360.0 * worldSizePixels(zoom)

    /**
     * Latitude is the hard axis: this is where the Mercator stretch happens.
     *
     * @param latitude Degrees. Clamped to [MAX_LATITUDE] first.
     * @param zoom The zoom level to project at.
     */
    fun latitudeToWorldY(latitude: Double, zoom: Int): Double {
        val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
        val radians = clamped * PI / 180.0
        // asinh(tan(lat)) is the numerically stable form of ln(tan + sec);
        // the naive version loses precision near the equator.
        val mercatorY = asinh(tan(radians))
        return (1.0 - mercatorY / PI) / 2.0 * worldSizePixels(zoom)
    }

    /** Inverse of [longitudeToWorldX]. */
    fun worldXToLongitude(x: Double, zoom: Int): Double =
        x / worldSizePixels(zoom) * 360.0 - 180.0

    /** Inverse of [latitudeToWorldY]. */
    fun worldYToLatitude(y: Double, zoom: Int): Double {
        val mercatorY = (1.0 - 2.0 * y / worldSizePixels(zoom)) * PI
        return atan(sinh(mercatorY)) * 180.0 / PI
    }

    /** Projects a real-world coordinate onto the pixel plane. */
    fun toWorldPixel(point: GeoPoint, zoom: Int): WorldPixel = WorldPixel(
        x = longitudeToWorldX(point.longitude, zoom),
        y = latitudeToWorldY(point.latitude, zoom),
    )

    /**
     * Turns a pixel on the map back into a real-world coordinate — what the
     * picker calls when the user drops a pin.
     *
     * Longitude is **wrapped** rather than clamped: dragging the map past the
     * anti-meridian should wrap the world round, not pin the marker to 180
     * degrees. Latitude *is* clamped, because there is nothing past the
     * projection's poles to wrap to.
     *
     * @param pixel A point on the projected plane.
     * @param zoom The zoom level [pixel] was measured at.
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
     * How many metres one screen pixel covers, here and now.
     *
     * This is what converts the domain's 50-metre radius into a circle of the
     * right size on screen.
     *
     * It shrinks with `cos(latitude)`, which is the Mercator stretch again: a
     * 50 m circle is visibly larger in pixels in Oslo than in Dhaka at the
     * same zoom level. Ignoring that draws a fence that lies about its own
     * size — the user would see a circle that does not match the rule being
     * enforced.
     *
     * @param latitude Where on Earth the measurement is being taken.
     * @param zoom The current zoom level.
     */
    fun metresPerPixel(latitude: Double, zoom: Int): Double {
        val clamped = latitude.coerceIn(-MAX_LATITUDE, MAX_LATITUDE)
        return EQUATORIAL_METRES_PER_PIXEL * cos(clamped * PI / 180.0) / (1 shl zoom)
    }

    /**
     * Which tile image contains [pixel] — the download address for that part
     * of the map.
     */
    fun tileAt(pixel: WorldPixel, zoom: Int): TileCoordinate = TileCoordinate(
        x = floor(pixel.x / TILE_SIZE).toInt(),
        y = floor(pixel.y / TILE_SIZE).toInt(),
        zoom = zoom,
    )

    /**
     * The raw Mercator y for a latitude, unscaled by zoom.
     *
     * Not used by the app; kept because it states the projection in its
     * textbook form, which makes the tests readable against a reference.
     */
    internal fun mercatorY(latitudeDegrees: Double): Double =
        ln(tan(PI / 4.0 + latitudeDegrees * PI / 360.0))
}

/**
 * A point on the projected world plane, in pixels, at a specific zoom.
 *
 * Deliberately a distinct type from [GeoPoint] so the two can never be
 * confused — passing a pixel where a coordinate was expected is a compile
 * error rather than a map drawn in the wrong ocean.
 */
data class WorldPixel(val x: Double, val y: Double)
