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
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.log2
import kotlin.math.roundToInt

/**
 * The slippy map: tiles, the dropped centre pin, and the user's own position.
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

    /**
     * Decoded tiles, filled off the main thread.
     *
     * `BitmapFactory.decodeByteArray` used to run inside the draw pass, which
     * meant the first frame showing a new row of tiles spent tens of
     * milliseconds decoding PNGs before it could draw anything - a dropped
     * frame every time the user panned onto fresh imagery. Decoding here and
     * drawing only what is already decoded keeps the draw pass to blits.
     */
    val decoded = remember { mutableStateMapOf<TileCoordinate, ImageBitmap>() }

    val currentCentre by rememberUpdatedState(centre)
    val currentZoom by rememberUpdatedState(zoom)

    // Where the pinch has got to *between* integer levels. Re-synced whenever
    // the zoom changes from outside a gesture - the +/- buttons, or the office
    // the screen opened on - so the next pinch starts from what is on screen.
    val pinchZoom = remember { mutableFloatStateOf(zoom.toFloat()) }
    LaunchedEffect(zoom) {
        if (pinchZoom.floatValue.roundToInt() != zoom) pinchZoom.floatValue = zoom.toFloat()
    }

    // The world pixel under the top-left corner of the viewport.
    val centreWorld = WebMercator.toWorldPixel(centre, zoom)
    val topLeft = WorldPixel(
        x = centreWorld.x - (viewport.width / 2.0) / pixelScale,
        y = centreWorld.y - (viewport.height / 2.0) / pixelScale,
    )

    LaunchedEffect(tiles) {
        // Whatever left `tiles` is gone for good; holding its bitmap is the
        // difference between a bounded cache and a slow leak.
        decoded.keys.retainAll(tiles.keys)

        val fresh = tiles.filterKeys { it !in decoded }
        if (fresh.isEmpty()) return@LaunchedEffect

        val bitmaps = withContext(Dispatchers.Default) {
            fresh.mapNotNull { (coordinate, bytes) ->
                // decodeByteArray returns null rather than throwing on
                // malformed data, and the `runCatching` covers the rest:
                // corrupt imagery must not take down a screen the user is
                // standing outside trying to use.
                runCatching {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
                }.getOrNull()?.let { coordinate to it }
            }
        }
        decoded.putAll(bitmaps)
    }

    // Recomputed every frame - it is a dozen integer divisions - but the
    // effect below only relaunches when the *set* changes. Keying on `centre`
    // instead meant a fresh coroutine, a fresh tile list and a round trip
    // through the ViewModel on every frame of every drag.
    val visible = visibleTiles(topLeft, viewport, pixelScale, zoom)

    LaunchedEffect(visible) {
        if (viewport == IntSize.Zero) return@LaunchedEffect
        onTilesRequested(visible)
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
                        // `gestureZoom` is the scale change since the *last
                        // pointer event*, not since the pinch began. The old
                        // code compared that single-frame delta against a
                        // threshold of 1.27x, which one 16 ms frame of a human
                        // pinch never reaches - so pinching did nothing at all.
                        //
                        // Accumulating into a fractional zoom level fixes it
                        // and is self-correcting: it is an absolute position,
                        // so it cannot drift the way a running delta does, and
                        // rounding puts the step at the natural halfway point.
                        pinchZoom.floatValue = (pinchZoom.floatValue + log2(gestureZoom))
                            .coerceIn(minZoom.toFloat(), maxZoom.toFloat())

                        val stepped = pinchZoom.floatValue.roundToInt()
                        if (stepped != currentZoom) onZoomChanged(stepped)
                    }
                }
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawTiles(decoded, topLeft, pixelScale, zoom, tileDisplayPx)

            val centrePx = Offset(size.width / 2f, size.height / 2f)

            userLocation?.let { user ->
                drawUserDot(user, topLeft, pixelScale, zoom, colors.primary, density.density)
            }

            // No perimeter ring. Drawing the 50 m radius here made the picker
            // look like it was measuring something, and it is not: it records
            // a coordinate. The radius is real, but it belongs on the screen
            // where it decides an outcome - the Attendance dial - not around a
            // pin the user is still dragging.
            drawLocationPin(centrePx, colors.mapMarker, density.density)
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

/**
 * Blits whatever is already decoded. A tile that has arrived but not yet been
 * decoded is simply skipped this frame; the grid shows through for one frame
 * instead of the frame being spent decoding it.
 */
private fun DrawScope.drawTiles(
    decoded: Map<TileCoordinate, ImageBitmap>,
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
            val image = decoded[coordinate.wrapped()] ?: continue

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
 * The dropped pin at the exact centre of the viewport.
 *
 * This was a crosshair, on the reasoning that a teardrop's bulk sits above its
 * point and users therefore read the wrong pixel as the chosen spot. The
 * objection is real; the answer is the [shadow] rather than a different shape.
 * A crosshair is a *targeting* symbol - it says "aim here", which invites the
 * reading that the app is measuring whether the aim is good enough. It is not:
 * the office goes wherever it is dropped, and the only measurement that
 * matters happens later, at check-in. A pin says "placed", which is the truth.
 *
 * [tip] is the coordinate being chosen; everything is drawn above it.
 */
private fun DrawScope.drawLocationPin(tip: Offset, color: Color, density: Float) {
    val headRadius = 11f * density
    val height = 34f * density
    val head = Offset(tip.x, tip.y - height + headRadius)

    // The shadow, and the whole answer to "which pixel is it?" - it sits on
    // the chosen coordinate itself, so the pin reads as standing on a spot
    // rather than floating over a neighbourhood.
    drawOval(
        color = Color.Black.copy(alpha = 0.20f),
        topLeft = Offset(tip.x - 5f * density, tip.y - 2f * density),
        size = Size(width = 10f * density, height = 4f * density),
    )

    // A tapered body whose apex is the tip; the head circle rounds off its top
    // into a teardrop.
    val body = Path().apply {
        moveTo(tip.x, tip.y)
        lineTo(head.x - headRadius * 0.87f, head.y + headRadius * 0.5f)
        lineTo(head.x + headRadius * 0.87f, head.y + headRadius * 0.5f)
        close()
    }

    // White underneath, as a halo. Map tiles run from near-white motorways to
    // dark parkland, and a red marker on either alone would disappear into it.
    drawPath(path = body, color = Color.White, style = Stroke(width = 3f * density))
    drawCircle(color = Color.White, radius = headRadius + 1.5f * density, center = head)

    drawPath(path = body, color = color)
    drawCircle(color = color, radius = headRadius, center = head)
    drawCircle(color = Color.White, radius = headRadius * 0.42f, center = head)
}

private const val TILE_DISPLAY_DP = 256
