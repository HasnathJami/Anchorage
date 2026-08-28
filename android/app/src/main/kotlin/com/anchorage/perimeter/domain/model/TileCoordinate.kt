package com.anchorage.perimeter.domain.model

/**
 * One square of the slippy-map grid.
 *
 * [x] and [y] are wrapped and bounds-checked by [isValid] rather than in the
 * constructor: panning across the anti-meridian legitimately produces an `x`
 * outside the grid, and the fix for that is to wrap it, not to throw in the
 * middle of a drag gesture.
 */
data class TileCoordinate(val x: Int, val y: Int, val zoom: Int) {

    /** Tiles per side at this zoom. */
    val gridSize: Int get() = 1 shl zoom

    /**
     * The same tile with [x] wrapped into the grid.
     *
     * Longitude wraps; latitude does not, which is why only `x` is folded.
     */
    fun wrapped(): TileCoordinate {
        val size = gridSize
        val wrappedX = ((x % size) + size) % size
        return if (wrappedX == x) this else copy(x = wrappedX)
    }

    /** False for rows above the north edge or below the south edge. */
    val isValid: Boolean get() = y in 0 until gridSize && zoom >= 0
}
