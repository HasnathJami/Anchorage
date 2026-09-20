package com.anchorage.perimeter.core.designsystem.component

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme

/**
 * **The big circle on the attendance screen.** A ring whose sweep shows how
 * far through the geofence radius the user is, with the live distance printed
 * at its centre.
 *
 * ```
 *        ╭───────────╮
 *      ╭─┤   120m    ├─╮     ← valueLabel
 *      │ │   AWAY    │ │     ← captionLabel
 *      ╰─┴───────────┴─╯
 *      ▲ arc sweeps clockwise from 12 o'clock as distance grows
 * ```
 *
 * ## Design notes
 *
 * - The arc starts at 12 o'clock (`-90` degrees) and sweeps clockwise, so
 *   "more arc" reads unambiguously as "further away".
 * - **Progress and colour are both animated.** Raw GPS jitters by a few
 *   metres a second; without the 450 ms tween the ring visibly twitches and
 *   the screen feels broken even when the data is fine.
 * - A minimum sweep of 2 degrees is enforced, so standing exactly on the
 *   anchor still renders a visible tick rather than a bare track.
 * - **The whole dial is one semantic node.** A screen reader announcing
 *   "120" and "AWAY" as two unrelated items is useless, so the caller passes
 *   one complete [contentDescription] instead.
 *
 * ## A note for whoever animates this next
 *
 * The *value* is animated and then formatted — never the other way round.
 * Animating a formatted string is what made the ring glide smoothly while the
 * read-out flickered 120 – 118 – 121 underneath it. See `ProximityReadout`,
 * which owns that animation and passes the finished text in here.
 *
 * @param valueLabel The big number, already formatted — "120m", "1.4 km".
 * @param captionLabel The small word beneath it, normally "AWAY".
 * @param progress How full the arc should be: `0f` at the anchor, `1f` at or
 *   beyond the fence edge. Clamped internally, so out-of-range is safe.
 * @param arcColor The ring colour, carrying the in-range / out-of-range
 *   status. Animated when it changes.
 * @param fillColor A soft wash inside the ring that carries the same status
 *   colour into the middle without competing with the numeral.
 * @param contentDescription The complete sentence a screen reader announces.
 *   Must be the *real* number, not the tween's current frame.
 * @param modifier Standard Compose modifier.
 * @param diameter Outer size of the dial.
 * @param strokeWidth Thickness of the ring.
 */
@Composable
fun DistanceDial(
    valueLabel: String,
    captionLabel: String,
    progress: Float,
    arcColor: Color,
    fillColor: Color,
    contentDescription: String,
    modifier: Modifier = Modifier,
    diameter: Dp = 186.dp,
    strokeWidth: Dp = 12.dp,
) {
    val colors = AnchorageTheme.colors

    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(durationMillis = 450, easing = FastOutSlowInEasing),
        label = "dial-progress",
    )
    val animatedArcColor by animateColorAsState(
        targetValue = arcColor,
        animationSpec = tween(durationMillis = 300),
        label = "dial-arc-colour",
    )

    Box(
        modifier = modifier
            .size(diameter)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.size(diameter)) {
            val stroke = strokeWidth.toPx()
            val inset = stroke / 2f
            val arcSize = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(inset, inset)

            // Inner tint: a soft wash that carries the status colour into the
            // middle of the dial without competing with the numeral.
            drawCircle(
                color = fillColor,
                radius = (size.minDimension - stroke * 2f) / 2f,
                center = center,
            )

            drawArc(
                color = colors.dialTrack,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )

            drawArc(
                color = animatedArcColor,
                startAngle = -90f,
                sweepAngle = (animatedProgress * 360f).coerceAtLeast(MIN_VISIBLE_SWEEP_DEGREES),
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = valueLabel,
                style = AnchorageTheme.typography.dialValue,
                color = colors.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                text = captionLabel,
                style = AnchorageTheme.typography.microLabel,
                color = colors.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

private const val MIN_VISIBLE_SWEEP_DEGREES = 2f

@Preview(showBackground = true, backgroundColor = 0xFFF5FAFA)
@Composable
private fun DistanceDialOutOfRangePreview() {
    AnchorageTheme {
        DistanceDial(
            valueLabel = "120m",
            captionLabel = "AWAY",
            progress = 1f,
            arcColor = AnchorageTheme.colors.dangerArc,
            fillColor = AnchorageTheme.colors.dangerDialFill,
            contentDescription = "120 metres away from the office",
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFFF5FAFA)
@Composable
private fun DistanceDialInRangePreview() {
    AnchorageTheme {
        DistanceDial(
            valueLabel = "12m",
            captionLabel = "AWAY",
            progress = 0.24f,
            arcColor = AnchorageTheme.colors.successArc,
            fillColor = AnchorageTheme.colors.successDialFill,
            contentDescription = "12 metres away from the office",
        )
    }
}
