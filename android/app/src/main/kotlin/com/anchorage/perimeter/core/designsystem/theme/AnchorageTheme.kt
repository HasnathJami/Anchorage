package com.anchorage.perimeter.core.designsystem.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Corner radii, named for the component that owns them. */
data class AnchorageShapes(
    val card: Shape = RoundedCornerShape(20.dp),
    val mapThumbnail: Shape = RoundedCornerShape(14.dp),
    val button: Shape = RoundedCornerShape(12.dp),
    val primaryButton: Shape = RoundedCornerShape(14.dp),
    val pill: Shape = RoundedCornerShape(percent = 50),
    val dashedPanel: Shape = RoundedCornerShape(20.dp),
    val banner: Shape = RoundedCornerShape(14.dp),
)

/**
 * A 4dp spacing ladder.
 *
 * Hard-coded `16.dp` literals scattered through a screen are how layouts drift
 * out of rhythm; every gap in Anchorage names a rung of this scale instead.
 */
data class AnchorageSpacing(
    val xxs: Dp = 4.dp,
    val xs: Dp = 8.dp,
    val sm: Dp = 12.dp,
    val md: Dp = 16.dp,
    val lg: Dp = 20.dp,
    val xl: Dp = 24.dp,
    val xxl: Dp = 32.dp,
    val screenHorizontal: Dp = 16.dp,
)

private val LocalAnchorageColors = staticCompositionLocalOf { AnchorageColors() }
private val LocalAnchorageTypography = staticCompositionLocalOf { AnchorageTypography() }
private val LocalAnchorageShapes = staticCompositionLocalOf { AnchorageShapes() }
private val LocalAnchorageSpacing = staticCompositionLocalOf { AnchorageSpacing() }

/**
 * The design-system entry point.
 *
 * It wraps [MaterialTheme] rather than replacing it, so Material 3 components
 * (ripples, text selection handles, the system bar scrim) stay coherent, while
 * Anchorage's own tokens are reached through the [AnchorageTheme] object.
 */
@Composable
fun AnchorageTheme(
    colors: AnchorageColors = AnchorageColors(),
    typography: AnchorageTypography = AnchorageTypography(),
    shapes: AnchorageShapes = AnchorageShapes(),
    spacing: AnchorageSpacing = AnchorageSpacing(),
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(
        LocalAnchorageColors provides colors,
        LocalAnchorageTypography provides typography,
        LocalAnchorageShapes provides shapes,
        LocalAnchorageSpacing provides spacing,
    ) {
        MaterialTheme(
            colorScheme = lightColorScheme(
                primary = colors.primary,
                onPrimary = colors.onPrimary,
                background = colors.backgroundTop,
                surface = colors.surface,
                onSurface = colors.textPrimary,
                error = colors.dangerText,
            ),
            content = content,
        )
    }
}

/** Token accessors: `AnchorageTheme.colors.primary`, `AnchorageTheme.spacing.md`, ... */
object AnchorageTheme {
    val colors: AnchorageColors
        @Composable @ReadOnlyComposable get() = LocalAnchorageColors.current

    val typography: AnchorageTypography
        @Composable @ReadOnlyComposable get() = LocalAnchorageTypography.current

    val shapes: AnchorageShapes
        @Composable @ReadOnlyComposable get() = LocalAnchorageShapes.current

    val spacing: AnchorageSpacing
        @Composable @ReadOnlyComposable get() = LocalAnchorageSpacing.current
}
