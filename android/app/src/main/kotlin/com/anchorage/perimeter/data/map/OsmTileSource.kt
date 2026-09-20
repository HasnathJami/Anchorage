package com.anchorage.perimeter.data.map

import android.util.LruCache
import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.TileCoordinate
import com.anchorage.perimeter.domain.port.MapTileSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Downloads map tile images from OpenStreetMap.
 *
 * **This is the only outbound network call in the entire Android app.**
 * Everything else is on-device.
 *
 * ## This class never throws
 *
 * Every `IOException`, DNS failure, timeout and non-200 response is
 * translated into an [AppError.MapTiles] case and returned as a value. A
 * tile server having a bad day must not be able to take down the screen a
 * user is standing in a car park trying to use — the picker falls back to a
 * plain grid and a pin can still be dropped.
 *
 * ## Why `HttpURLConnection` and not OkHttp or Retrofit
 *
 * One `GET` returning a few kilobytes of PNG does not justify a networking
 * stack. `HttpURLConnection` is in the JDK, so the dependency list — and the
 * APK — stay where they are.
 *
 * ## Two policy details that are not optional
 *
 * - **A real `User-Agent`.** OpenStreetMap's tile usage policy rejects
 *   requests with a default or absent agent, and Java sends one that looks
 *   like a bot. A 403 with no explanation is the failure mode that one line
 *   prevents.
 * - **Attribution.** The imagery is ODbL-licensed. [attribution] is rendered
 *   on the map and is a legal requirement, not decoration.
 *
 * @param dispatchers Supplies the IO thread the request runs on.
 */
@Singleton
class OsmTileSource @Inject constructor(
    private val dispatchers: DispatcherProvider,
) : MapTileSource {

    /**
     * A small in-memory cache, sized in tiles rather than bytes.
     *
     * A pan gesture revisits the same tiles constantly; without this, every
     * wobble of a thumb is a fresh HTTP request. 128 tiles is roughly nine
     * screenfuls at this tile size — enough to make panning feel free, small
     * enough (about 10 MB of PNG) to be irrelevant to the heap.
     */
    private val cache = LruCache<TileCoordinate, ByteArray>(CACHE_ENTRIES)

    override val attribution: String = "© OpenStreetMap contributors"

    /**
     * Fetches one tile, from the cache when possible.
     *
     * @param tile Which tile to fetch.
     * @return The PNG bytes, or a typed [AppError.MapTiles] failure. Never
     *   throws, except [CancellationException].
     */
    override suspend fun load(tile: TileCoordinate): Outcome<ByteArray> {
        // Step 1 - fold an out-of-range column back into the grid, which is
        // what panning past the anti-meridian produces.
        val normalised = tile.wrapped()
        if (!normalised.isValid) {
            // Above the north edge or below the south edge: there is no tile
            // to fetch. Not an error worth a dialog - the map simply has no
            // imagery there, so report it as a rejection and let the canvas
            // draw its fallback grid.
            return Outcome.Failure(AppError.MapTiles.ServerRejected(statusCode = HTTP_NOT_FOUND))
        }

        // Step 2 - already downloaded? Then no request at all.
        cache.get(normalised)?.let { return Outcome.Success(it) }

        // Step 3 - go to the network, on an IO thread.
        return withContext(dispatchers.io) {
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(urlFor(normalised)).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = CONNECT_TIMEOUT_MILLIS
                    readTimeout = READ_TIMEOUT_MILLIS
                    setRequestProperty("User-Agent", USER_AGENT)
                }

                when (val status = connection.responseCode) {
                    HttpURLConnection.HTTP_OK -> {
                        val bytes = connection.inputStream.use { it.readBytes() }
                        cache.put(normalised, bytes)
                        Outcome.Success(bytes)
                    }

                    else -> Outcome.Failure(AppError.MapTiles.ServerRejected(statusCode = status))
                }
            } catch (cancellation: CancellationException) {
                // Structured concurrency: a cancelled pan must cancel, not be
                // reported to the user as a network fault.
                throw cancellation
            } catch (timeout: SocketTimeoutException) {
                Outcome.Failure(
                    AppError.MapTiles.Timeout(
                        waitedMillis = (CONNECT_TIMEOUT_MILLIS + READ_TIMEOUT_MILLIS).toLong(),
                        cause = timeout,
                    ),
                )
            } catch (host: UnknownHostException) {
                // DNS failed, which in practice means "no network" far more
                // often than "this host does not exist".
                Outcome.Failure(AppError.MapTiles.Offline(cause = host))
            } catch (io: IOException) {
                Outcome.Failure(AppError.MapTiles.Offline(cause = io))
            } catch (throwable: Throwable) {
                // The contract is "never throws", and that has to hold for
                // the failure nobody predicted too.
                Outcome.Failure(AppError.MapTiles.Offline(cause = throwable))
            } finally {
                connection?.disconnect()
            }
        }
    }

    /** OpenStreetMap's standard tile URL layout. */
    private fun urlFor(tile: TileCoordinate): String =
        "https://tile.openstreetmap.org/${tile.zoom}/${tile.x}/${tile.y}.png"

    private companion object {
        /** About nine screenfuls of tiles. See the note on `cache`. */
        const val CACHE_ENTRIES = 128

        const val CONNECT_TIMEOUT_MILLIS = 8_000
        const val READ_TIMEOUT_MILLIS = 8_000
        const val HTTP_NOT_FOUND = 404

        /** Required by OSM's tile usage policy. See the class docs. */
        const val USER_AGENT = "AnchoragePerimeter/1.0 (attendance geofence; assessment build)"
    }
}
