package com.anchorage.perimeter.domain.model

/**
 * The address of one map tile: "column [x], row [y], at zoom level [zoom]".
 *
 * Online maps are jigsaws of 256x256 pixel images. This triple is how you ask
 * for one of those pieces — OpenStreetMap's URLs are literally
 * `https://tile.openstreetmap.org/{zoom}/{x}/{y}.png`.
 *
 * At zoom `z` the world is a grid of `2^z` by `2^z` tiles: one tile at zoom
 * 0, four at zoom 1, and so on.
 *
 * ## Why validity is a property, not a constructor check
 *
 * Unlike [GeoPoint], this type does **not** throw on out-of-range values.
 * Panning the map across the anti-meridian legitimately produces an `x`
 * outside the grid, and the fix for that is to wrap it — not to throw in the
 * middle of a drag gesture. So callers use [wrapped] and [isValid] instead.
 *
 * @property x Column index, west to east.
 * @property y Row index, north to south.
 * @property zoom Zoom level. Higher means more detail and more tiles.
 */
data class TileCoordinate(val x: Int, val y: Int, val zoom: Int) {

    /** How many tiles per side at this zoom: `2^zoom`. */
    val gridSize: Int get() = 1 shl zoom

    /**
     * The same tile with [x] folded back into the grid.
     *
     * Longitude wraps around the globe; latitude does not, which is why only
     * `x` is folded. The double modulo handles negative values, which a bare
     * `%` in Kotlin would leave negative.
     */
    fun wrapped(): TileCoordinate {
        val size = gridSize
        val wrappedX = ((x % size) + size) % size
        return if (wrappedX == x) this else copy(x = wrappedX)
    }

    /**
     * False for rows above the north edge or below the south edge — there is
     * no tile to fetch there, and asking would waste a request.
     */
    val isValid: Boolean get() = y in 0 until gridSize && zoom >= 0
}
