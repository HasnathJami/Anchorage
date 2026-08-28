package com.anchorage.perimeter.core.designsystem.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme

/**
 * The white rounded surface every section of the Attendance screen sits on.
 *
 * Elevation is kept at 1dp with a custom shadow colour: Material's default
 * black shadow reads as grey smudge against the minted background of this
 * design, where the reference uses a barely-there lift.
 */
@Composable
fun AnchorageCard(
    modifier: Modifier = Modifier,
    contentPadding: Dp = 18.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = AnchorageTheme.shapes.card,
        colors = CardDefaults.cardColors(containerColor = AnchorageTheme.colors.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
    ) {
        Column(modifier = Modifier.padding(contentPadding), content = content)
    }
}

/** Uppercase, wide-tracked section heading with an optional status dot. */
@Composable
fun SectionEyebrow(
    text: String,
    modifier: Modifier = Modifier,
    trailingDotColor: Color? = null,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = text,
            style = AnchorageTheme.typography.sectionEyebrow,
            color = AnchorageTheme.colors.labelMuted,
            modifier = Modifier.weight(1f),
        )
        trailingDotColor?.let { dotColor ->
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(dotColor),
            )
        }
    }
}

/**
 * The status chip under the dial: "OUT OF RANGE", "IN RANGE", "CHECKED IN".
 *
 * Colour alone never carries the meaning - the label always spells it out -
 * so the state survives both greyscale printing and colour-blind users.
 */
@Composable
fun StatusPill(
    text: String,
    containerColor: Color,
    contentColor: Color,
    modifier: Modifier = Modifier,
    leadingDot: Boolean = true,
) {
    Row(
        modifier = modifier
            .clip(AnchorageTheme.shapes.pill)
            .background(containerColor)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (leadingDot) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(contentColor),
            )
            Spacer(Modifier.width(7.dp))
        }
        Text(
            text = text,
            style = AnchorageTheme.typography.microLabel,
            color = contentColor,
        )
    }
}

/**
 * A rounded rectangle drawn with a dashed outline.
 *
 * Compose has no dashed border modifier, so the stroke is drawn directly with
 * a [PathEffect]. Drawing behind the content (rather than clipping to it)
 * keeps the dash pattern crisp at any corner radius.
 */
@Composable
fun DashedPanel(
    modifier: Modifier = Modifier,
    borderColor: Color = AnchorageTheme.colors.outlineDashed,
    cornerRadius: Dp = 20.dp,
    strokeWidth: Dp = 1.5.dp,
    dashLength: Dp = 7.dp,
    gapLength: Dp = 6.dp,
    contentPadding: Dp = 22.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                val stroke = strokeWidth.toPx()
                val radius = CornerRadius(cornerRadius.toPx(), cornerRadius.toPx())
                drawRoundRect(
                    color = borderColor,
                    topLeft = Offset(stroke / 2f, stroke / 2f),
                    size = Size(size.width - stroke, size.height - stroke),
                    cornerRadius = radius,
                    style = Stroke(
                        width = stroke,
                        pathEffect = PathEffect.dashPathEffect(
                            intervals = floatArrayOf(dashLength.toPx(), gapLength.toPx()),
                        ),
                    ),
                )
            }
            .padding(contentPadding),
        horizontalAlignment = Alignment.CenterHorizontally,
        content = content,
    )
}

/** The filled, full-width call to action. */
@Composable
fun AnchoragePrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    leadingIcon: ImageVector? = null,
    height: Dp = 54.dp,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .fillMaxWidth()
            .height(height),
        shape = AnchorageTheme.shapes.primaryButton,
        colors = ButtonDefaults.buttonColors(
            containerColor = AnchorageTheme.colors.primary,
            contentColor = AnchorageTheme.colors.onPrimary,
            disabledContainerColor = AnchorageTheme.colors.disabledContainer,
            disabledContentColor = AnchorageTheme.colors.onDisabledContainer,
        ),
        contentPadding = ButtonDefaults.ContentPadding,
    ) {
        leadingIcon?.let {
            Icon(imageVector = it, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text = text, style = AnchorageTheme.typography.button)
    }
}

/** The outlined secondary action, e.g. "Set Office Location". */
@Composable
fun AnchorageOutlinedButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    leadingIcon: ImageVector? = null,
    height: Dp = 52.dp,
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .fillMaxWidth()
            .height(height),
        shape = AnchorageTheme.shapes.button,
        border = BorderStroke(
            width = 1.5.dp,
            color = if (enabled) AnchorageTheme.colors.primary else AnchorageTheme.colors.outlineSubtle,
        ),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = AnchorageTheme.colors.primary,
            disabledContentColor = AnchorageTheme.colors.textTertiary,
        ),
    ) {
        leadingIcon?.let {
            Icon(imageVector = it, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text = text, style = AnchorageTheme.typography.button)
    }
}
