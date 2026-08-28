package com.anchorage.perimeter.presentation.officepicker.component

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.geo.WebMercator
import com.anchorage.perimeter.domain.geo.WorldPixel
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate
import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * The slippy map: tiles, the fixed centre crosshair, the perimeter ring and
 * the user's own position.
 *
 * All of the projection arithmetic lives in [WebMercator] rather than here, so
 * the part that is easy to get subtly wrong is covered by JVM tests while this
 * file stays a drawing routine.
 *
 * **Tiles are drawn [TILE_DISPLAY_DP] wide, not 256 device pixels.** A raster
 * tile blitted 1:1 onto a 3x-density screen is a postage stamp with unreadable
 * street names. Fixing the tile's *dp* size instead makes the map render at a
 * consistent physical scale on every device, which is why every world-pixel
 * measurement below is multiplied through [pixelScale].
 *
 * **Nothing here can throw on bad input.** A tile whose bytes fail to decode
 * is skipped and the grid shows through: corrupt imagery must not be able to
 * take down a screen the user is standing outside trying to use.
 */
@Composable
fun MapCanvas(
    centre: GeoPoint,
    zoom: Int,
    userLocation: GeoPoint?,
    radiusMeters: Double,
    isUserInsidePerimeter: Boolean?,
    tiles: Map<TileCoordinate, ByteArray>,
    onCentreMoved: (GeoPoint) -> Unit,
    onZoomChanged: (Int) -> Unit,
    onTilesRequested: (List<TileCoordinate>) -> Unit,
    minZoom: Int,
    maxZoom: Int,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val density = LocalDensity.current
    val tileDisplayPx = with(density) { TILE_DISPLAY_DP.dp.toPx() }
    val pixelScale = tileDisplayPx / WebMercator.TILE_SIZE

    var viewport by remember { mutableStateOf(IntSize.Zero) }

    // Decoding is memoised across recompositions: a pan gesture recomposes on
    // every frame, and re-decoding a dozen PNGs per frame would drop the map
    // to a slideshow.
    val decoded = remember { mutableMapOf<TileCoordinate, ImageBitmap?>() }

    val currentCentre by rememberUpdatedState(centre)
    val currentZoom by rememberUpdatedState(zoom)

    // The world pixel under the top-left corner of the viewport.
    val centreWorld = WebMercator.toWorldPixel(centre, zoom)
    val topLeft = WorldPixel(
        x = centreWorld.x - (viewport.width / 2.0) / pixelScale,
        y = centreWorld.y - (viewport.height / 2.0) / pixelScale,
    )

    LaunchedEffect(centre, zoom, viewport) {
        if (viewport == IntSize.Zero) return@LaunchedEffect
        onTilesRequested(visibleTiles(topLeft, viewport, pixelScale, zoom))
    }

    Box(
        modifier = modifier
            .background(colors.mapLand)
            .onSizeChanged { viewport = it }
            .pointerInput(minZoom, maxZoom) {
                detectTransformGestures { _, pan, gestureZoom, _ ->
                    if (pan != Offset.Zero) {
                        val world = WebMercator.toWorldPixel(currentCentre, currentZoom)
                        // Dragging the map right moves the camera left, hence
                        // the subtraction. Getting this sign wrong produces a
                        // map that runs away from the finger.
                        onCentreMoved(
                            WebMercator.toGeoPoint(
                                WorldPixel(
                                    x = world.x - pan.x / pixelScale,
                                    y = world.y - pan.y / pixelScale,
                                ),
                                currentZoom,
                            ),
                        )
                    }

                    if (gestureZoom != 1f) {
                        // Zoom levels are integers; a pinch only steps once it
                        // has travelled a full doubling, so the map does not
                        // flicker between levels mid-gesture.
                        val steps = (ln(gestureZoom.toDouble()) / ln(2.0)).let {
                            if (it > ZOOM_STEP_THRESHOLD) 1
                            else if (it < -ZOOM_STEP_THRESHOLD) -1
                            else 0
                        }
                        if (steps != 0) {
                            onZoomChanged((currentZoom + steps).coerceIn(minZoom, maxZoom))
                        }
                    }
                }
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawTiles(tiles, decoded, topLeft, pixelScale, zoom, tileDisplayPx)

            val metresPerPixel = WebMercator.metresPerPixel(centre.latitude, zoom) / pixelScale
            val radiusPx = (radiusMeters / metresPerPixel).toFloat()
            val centrePx = Offset(size.width / 2f, size.height / 2f)

            // The perimeter, in the same three states the Attendance dial uses:
            // green inside, red outside, and a neutral blue when the user's
            // own position is unknown - because claiming either colour without
            // knowing where they are would be inventing a fact.
            val ringColor = when (isUserInsidePerimeter) {
                true -> colors.successArc
                false -> colors.dangerArc
                null -> colors.primary
            }
            drawCircle(color = ringColor.copy(alpha = 0.14f), radius = radiusPx, center = centrePx)
            drawCircle(
                color = ringColor,
                radius = radiusPx,
                center = centrePx,
                style = Stroke(width = with(density) { 2.dp.toPx() }),
            )

            userLocation?.let { user ->
                drawUserDot(user, topLeft, pixelScale, zoom, colors.primary, density.density)
            }

            drawCrosshair(centrePx, ringColor, density.density)
        }
    }
}

/** Every tile touching the viewport, in draw order. */
private fun visibleTiles(
    topLeft: WorldPixel,
    viewport: IntSize,
    pixelScale: Float,
    zoom: Int,
): List<TileCoordinate> {
    val worldWidth = viewport.width / pixelScale
    val worldHeight = viewport.height / pixelScale
    val first = WebMercator.tileAt(topLeft, zoom)
    val last = WebMercator.tileAt(
        WorldPixel(topLeft.x + worldWidth, topLeft.y + worldHeight),
        zoom,
    )

    return buildList {
        for (y in first.y..last.y) {
            for (x in first.x..last.x) {
                add(TileCoordinate(x = x, y = y, zoom = zoom))
            }
        }
    }
}

private fun DrawScope.drawTiles(
    tiles: Map<TileCoordinate, ByteArray>,
    decoded: MutableMap<TileCoordinate, ImageBitmap?>,
    topLeft: WorldPixel,
    pixelScale: Float,
    zoom: Int,
    tileDisplayPx: Float,
) {
    val worldWidth = size.width / pixelScale
    val worldHeight = size.height / pixelScale
    val first = WebMercator.tileAt(topLeft, zoom)
    val last = WebMercator.tileAt(WorldPixel(topLeft.x + worldWidth, topLeft.y + worldHeight), zoom)

    for (y in first.y..last.y) {
        for (x in first.x..last.x) {
            val coordinate = TileCoordinate(x, y, zoom)
            val bytes = tiles[coordinate.wrapped()] ?: continue
            val image = decoded.getOrPut(coordinate.wrapped()) {
                // decodeByteArray returns null rather than throwing on
                // malformed data, and the `runCatching` covers the rest.
                runCatching {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
                }.getOrNull()
            } ?: continue

            val left = ((x * WebMercator.TILE_SIZE - topLeft.x) * pixelScale).toFloat()
            val top = ((y * WebMercator.TILE_SIZE - topLeft.y) * pixelScale).toFloat()

            drawImage(
                image = image,
                dstOffset = IntOffset(left.roundToInt(), top.roundToInt()),
                // Ceil rather than round, so neighbouring tiles overlap by a
                // pixel instead of leaving hairline seams between them.
                dstSize = IntSize(
                    width = (tileDisplayPx + 1).toInt(),
                    height = (tileDisplayPx + 1).toInt(),
                ),
            )
        }
    }
}

private fun DrawScope.drawUserDot(
    user: GeoPoint,
    topLeft: WorldPixel,
    pixelScale: Float,
    zoom: Int,
    color: Color,
    density: Float,
) {
    val world = WebMercator.toWorldPixel(user, zoom)
    val offset = Offset(
        x = ((world.x - topLeft.x) * pixelScale).toFloat(),
        y = ((world.y - topLeft.y) * pixelScale).toFloat(),
    )
    // Off-screen dots are skipped rather than clamped to the edge: a dot
    // pinned to the border reads as "you are here", which would be a lie.
    if (offset.x !in 0f..size.width || offset.y !in 0f..size.height) return

    drawCircle(color = Color.White, radius = 9f * density, center = offset)
    drawCircle(color = color, radius = 6f * density, center = offset)
}

/**
 * The fixed centre marker.
 *
 * A crosshair rather than a teardrop pin, and deliberately: a pin's *point* is
 * at its bottom tip while its bulk sits above, so users consistently read the
 * wrong pixel as the chosen spot. Crossed lines have no such ambiguity.
 */
private fun DrawScope.drawCrosshair(centre: Offset, color: Color, density: Float) {
    val arm = 14f * density
    val gap = 5f * density
    val stroke = 2f * density

    listOf(
        Offset(centre.x - arm, centre.y) to Offset(centre.x - gap, centre.y),
        Offset(centre.x + gap, centre.y) to Offset(centre.x + arm, centre.y),
        Offset(centre.x, centre.y - arm) to Offset(centre.x, centre.y - gap),
        Offset(centre.x, centre.y + gap) to Offset(centre.x, centre.y + arm),
    ).forEach { (start, end) ->
        drawLine(color = Color.White, start = start, end = end, strokeWidth = stroke * 2f)
        drawLine(color = color, start = start, end = end, strokeWidth = stroke)
    }

    drawCircle(color = Color.White, radius = 4.5f * density, center = centre)
    drawCircle(color = color, radius = 3f * density, center = centre)
}

private const val TILE_DISPLAY_DP = 256
private const val ZOOM_STEP_THRESHOLD = 0.34
