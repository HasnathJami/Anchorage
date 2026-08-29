package com.anchorage.perimeter.presentation.attendance.component

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.component.AnchoragePrimaryButton
import com.anchorage.perimeter.core.designsystem.component.DashedPanel
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.presentation.attendance.AttendanceUiState
import com.anchorage.perimeter.R

/**
 * The dashed panel at the foot of the screen.
 *
 * The padlock is the emotional core of the design: closed while any gate is
 * shut, open the moment every gate clears. It is animated with a [Crossfade]
 * so the transition registers as a state *change* rather than a repaint - the
 * user is being told something just became possible.
 *
 * The caption underneath always states the window, even when the window is the
 * reason the button is disabled, because "why can I not press this?" must be
 * answerable without leaving the screen.
 */
@Composable
fun CheckInPanel(
    state: AttendanceUiState,
    onMarkAttendance: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing
    val isMarked = state.isAlreadyMarkedToday
    val unlocked = state.canMarkAttendance

    DashedPanel(
        modifier = modifier,
        borderColor = when {
            isMarked -> colors.successArc
            unlocked -> colors.primary
            else -> colors.outlineDashed
        },
    ) {
        Crossfade(
            targetState = when {
                isMarked -> LockVisual.Done
                unlocked -> LockVisual.Open
                else -> LockVisual.Closed
            },
            label = "check-in-lock",
        ) { visual ->
            Icon(
                imageVector = when (visual) {
                    LockVisual.Done -> Icons.Outlined.CheckCircle
                    LockVisual.Open -> Icons.Outlined.LockOpen
                    LockVisual.Closed -> Icons.Outlined.Lock
                },
                contentDescription = stringResource(
                    if (visual == LockVisual.Closed) R.string.attendance_locked
                    else R.string.attendance_unlocked,
                ),
                tint = when (visual) {
                    LockVisual.Done -> colors.successText
                    LockVisual.Open -> colors.primary
                    LockVisual.Closed -> colors.labelMuted
                },
                modifier = Modifier.size(40.dp),
            )
        }

        Spacer(Modifier.height(spacing.md))

        if (state.isMarkingAttendance) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    // Matches the button it replaces, as a minimum: the height
                    // is here to stop the panel jumping during the swap, not
                    // to cap how tall the label may become.
                    .heightIn(min = 54.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = colors.primary,
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    text = stringResource(R.string.attendance_marking),
                    style = AnchorageTheme.typography.button,
                    color = colors.primary,
                )
            }
        } else {
            AnchoragePrimaryButton(
                text = stringResource(
                    if (isMarked) R.string.attendance_marked else R.string.attendance_mark,
                ),
                onClick = onMarkAttendance,
                enabled = unlocked && !state.isBusy,
                leadingIcon = if (isMarked) Icons.Outlined.CheckCircle else null,
                modifier = Modifier.semantics {
                    contentDescription = if (unlocked) "Mark attendance, available" else "Mark attendance, locked"
                },
            )
        }

        Spacer(Modifier.height(spacing.sm))

        Text(
            text = stringResource(
                if (state.isWindowOpen) R.string.attendance_available
                else R.string.attendance_window_closed,
                state.windowLabel,
            ),
            style = AnchorageTheme.typography.microLabel,
            color = if (state.isWindowOpen) colors.textTertiary else colors.cautionText,
        )
    }
}

private enum class LockVisual { Closed, Open, Done }
