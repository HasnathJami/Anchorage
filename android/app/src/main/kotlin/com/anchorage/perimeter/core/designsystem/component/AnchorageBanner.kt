package com.anchorage.perimeter.core.designsystem.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme

/**
 * The inline problem banner.
 *
 * A deliberate choice over a Snackbar or Toast: the conditions it reports -
 * permission missing, location switched off, signal too weak - are *persistent
 * states*, not momentary events. A transient toast would vanish before the
 * user could act on it and leave the screen looking inexplicably inert.
 *
 * Every banner carries an action, because a message that names a problem
 * without offering the fix is only half an answer.
 */
@Composable
fun AnchorageBanner(
    visible: Boolean,
    title: String,
    message: String,
    icon: ImageVector,
    containerColor: Color,
    contentColor: Color,
    actionLabel: String?,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
        modifier = modifier,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(AnchorageTheme.shapes.banner)
                .background(containerColor)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.Start,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = contentColor,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = AnchorageTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                    color = contentColor,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = message,
                    style = AnchorageTheme.typography.body,
                    color = AnchorageTheme.colors.textSecondary,
                )
                if (actionLabel != null) {
                    TextButton(
                        onClick = onAction,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(
                            horizontal = 0.dp,
                            vertical = 4.dp,
                        ),
                    ) {
                        Text(
                            text = actionLabel,
                            style = AnchorageTheme.typography.button,
                            color = contentColor,
                        )
                    }
                }
            }
        }
    }
}
