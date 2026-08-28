package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.TileCoordinate

/**
 * Where map imagery comes from.
 *
 * Returns raw bytes rather than a decoded bitmap so the port stays free of
 * Android graphics types - decoding is the presentation layer's job, and this
 * way the whole tile pipeline is testable with a fake that hands back four
 * bytes.
 *
 * **Implementations never throw.** A tile that fails to load is a cosmetic
 * problem, not a crash: the picker must keep working, with a plain grid behind
 * the pin, on a train with no signal.
 */
interface MapTileSource {

    suspend fun load(tile: TileCoordinate): Outcome<ByteArray>

    /** Attribution the UI is required to display for the imagery in use. */
    val attribution: String
}
