package com.anchorage.perimeter.core.designsystem.component

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MyLocation
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import kotlin.math.abs
import kotlin.random.Random

/**
 * A procedurally drawn map thumbnail.
 *
 * The brief supplies no Maps API key and a real `MapView` would mean a billed
 * dependency, a network round-trip and a second permission surface for what is
 * decoration in this card. Instead the tile is *generated* from the anchor's
 * own coordinates: the same office always renders the same street pattern, and
 * two different offices look visibly different, so the thumbnail still carries
 * the "this is your saved place" signal the reference design intends.
 *
 * Everything is drawn in normalised units and scaled at draw time, so it is
 * resolution-independent and costs one Canvas pass.
 */
@Composable
fun MiniMapPreview(
    latitude: Double?,
    longitude: Double?,
    coordinateLabel: String,
    modifier: Modifier = Modifier,
    height: Dp = 112.dp,
) {
    val colors = AnchorageTheme.colors

    // A deterministic seed: same place, same streets, across recompositions
    // and process restarts.
    val seed = remember(latitude, longitude) {
        if (latitude == null || longitude == null) {
            DEFAULT_SEED
        } else {
            (abs(latitude * 1_000_000).toLong() * 31 + abs(longitude * 1_000_000).toLong())
        }
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .clip(AnchorageTheme.shapes.mapThumbnail)
            .background(colors.mapLand),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val random = Random(seed)
            val w = size.width
            val h = size.height

            // Two park blocks.
            repeat(2) { index ->
                val px = random.nextFloat() * 0.6f
                val py = random.nextFloat() * 0.55f
                drawRect(
                    color = if (index == 0) colors.mapPark else colors.mapParkAlt,
                    topLeft = Offset(px * w, py * h),
                    size = Size(w * (0.20f + random.nextFloat() * 0.22f), h * 0.34f),
                )
            }

            // A river: one gentle diagonal band.
            drawLine(
                color = colors.mapWater,
                start = Offset(-0.1f * w, h * (0.2f + random.nextFloat() * 0.3f)),
                end = Offset(1.1f * w, h * (0.55f + random.nextFloat() * 0.3f)),
                strokeWidth = h * 0.07f,
                cap = StrokeCap.Round,
            )

            // Minor grid.
            repeat(5) {
                val y = h * random.nextFloat()
                drawLine(colors.mapRoadMinor, Offset(0f, y), Offset(w, y), strokeWidth = h * 0.012f)
                val x = w * random.nextFloat()
                drawLine(colors.mapRoadMinor, Offset(x, 0f), Offset(x, h), strokeWidth = h * 0.012f)
            }

            // Two arterial roads, drawn last so they sit on top.
            drawLine(
                color = colors.mapRoad,
                start = Offset(0f, h * 0.62f),
                end = Offset(w, h * 0.48f),
                strokeWidth = h * 0.045f,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = colors.mapRoad,
                start = Offset(w * 0.34f, 0f),
                end = Offset(w * 0.46f, h),
                strokeWidth = h * 0.038f,
                cap = StrokeCap.Round,
            )
        }

        CoordinateChip(label = coordinateLabel)
    }
}

/** The floating white read-out that sits over the map thumbnail. */
@Composable
fun CoordinateChip(
    label: String,
    modifier: Modifier = Modifier,
    iconTint: Color = AnchorageTheme.colors.primary,
) {
    Row(
        modifier = modifier
            .clip(AnchorageTheme.shapes.pill)
            .background(AnchorageTheme.colors.surface)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Outlined.MyLocation,
            contentDescription = null,
            tint = iconTint,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = label,
            style = AnchorageTheme.typography.coordinate,
            color = AnchorageTheme.colors.textSecondary,
        )
    }
}

/** A small solid dot; used for the marker and for legend bullets. */
@Composable
fun Dot(color: Color, size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(color),
    )
}

private const val DEFAULT_SEED = 20260828L

@Preview(showBackground = true)
@Composable
private fun MiniMapPreviewPreview() {
    AnchorageTheme {
        MiniMapPreview(
            latitude = 23.780887,
            longitude = 90.414391,
            coordinateLabel = "Lat: 23.7808, Lon: 90.4143",
            modifier = Modifier.padding(16.dp),
        )
    }
}
