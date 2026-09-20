package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.TileCoordinate

/**
 * Where the office picker's map imagery comes from.
 *
 * Implemented by [com.anchorage.perimeter.data.map.OsmTileSource], which
 * fetches raster tiles from OpenStreetMap. That is the **only** outbound
 * network call in the entire Android app.
 *
 * ## Why it returns raw bytes
 *
 * Returning `ByteArray` rather than a decoded `Bitmap` keeps the port free of
 * Android graphics types. Decoding is the presentation layer's job. The
 * payoff is that the whole tile pipeline can be tested with a fake that hands
 * back four bytes.
 *
 * ## Implementations never throw
 *
 * A tile that fails to load is a cosmetic problem, not a crash. The picker
 * must keep working — with a plain grid behind the pin — on a train with no
 * signal. Every failure is translated into
 * [com.anchorage.perimeter.core.common.error.AppError.MapTiles] at the
 * boundary.
 */
interface MapTileSource {

    /**
     * Fetches one 256x256 map tile.
     *
     * @param tile Which tile to fetch — see [TileCoordinate].
     * @return The encoded image bytes, or a typed failure. Never throws.
     */
    suspend fun load(tile: TileCoordinate): Outcome<ByteArray>

    /**
     * The attribution text the UI is legally required to display for the
     * imagery in use — "(c) OpenStreetMap contributors".
     */
    val attribution: String
}
