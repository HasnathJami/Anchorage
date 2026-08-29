package com.anchorage.perimeter.presentation.attendance.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.component.AnchorageCard
import com.anchorage.perimeter.core.designsystem.component.AnchorageOutlinedButton
import com.anchorage.perimeter.core.designsystem.component.MiniMapPreview
import com.anchorage.perimeter.core.designsystem.component.SectionEyebrow
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.presentation.attendance.AttendanceFormatters
import com.anchorage.perimeter.presentation.attendance.AttendanceUiState
import com.anchorage.perimeter.R
import androidx.compose.animation.animateContentSize
import com.anchorage.perimeter.domain.model.AnchorSource

/**
 * "STEP 1: OFFICE CONTEXT" - the card that captures and displays the anchor.
 *
 * The status dot in the eyebrow is the card's whole state indicator: blue once
 * an office is anchored, grey while it is not. It mirrors the reference design
 * and gives the section a glanceable answer to "is step 1 done?".
 */
@Composable
fun OfficeContextCard(
    state: AttendanceUiState,
    onSetOfficeLocation: () -> Unit,
    onClearOffice: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing
    val anchor = state.anchor

    // Setting the office adds a whole row to this card, and swapping the
    // button for a spinner changes its height again. Appearing instantly makes
    // the card - and everything below it - jump. The user has just pressed a
    // button; the screen answering with a lurch reads as a glitch rather than
    // as a result. One modifier smooths every size change the card can make,
    // which is why it sits here rather than on each of them.
    AnchorageCard(modifier = modifier.animateContentSize()) {
        SectionEyebrow(
            text = stringResource(R.string.attendance_step_one),
            trailingDotColor = if (anchor != null) colors.primary else colors.outlineSubtle,
        )

        Spacer(Modifier.height(spacing.sm))

        MiniMapPreview(
            latitude = anchor?.point?.latitude,
            longitude = anchor?.point?.longitude,
            coordinateLabel = anchor?.let {
                stringResource(
                    R.string.attendance_coordinates,
                    AttendanceFormatters.coordinate(it.point.latitude),
                    AttendanceFormatters.coordinate(it.point.longitude),
                )
            } ?: stringResource(R.string.attendance_coordinates_empty),
        )

        Spacer(Modifier.height(spacing.sm))

        Text(
            text = if (anchor == null) {
                stringResource(R.string.attendance_office_help)
            } else {
                stringResource(
                    R.string.attendance_office_help_configured,
                    state.radiusMeters.toInt(),
                )
            },
            style = AnchorageTheme.typography.body,
            color = colors.textSecondary,
        )

        if (anchor != null) {
            Spacer(Modifier.height(spacing.xxs))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    // A hand-placed pin has no measured accuracy, so it is not
                    // given one. Rendering "±0 m" for it would claim a
                    // precision nobody measured.
                    text = when (anchor.source) {
                        AnchorSource.ManualPlacement ->
                            stringResource(R.string.anchor_placed_manually)

                        AnchorSource.GpsFix -> stringResource(
                            R.string.attendance_anchor_accuracy,
                            AttendanceFormatters.accuracy(anchor.accuracyMeters),
                        )
                    },
                    style = AnchorageTheme.typography.caption,
                    color = colors.textTertiary,
                )
                TextButton(onClick = onClearOffice) {
                    Text(
                        text = stringResource(R.string.attendance_clear_office),
                        style = AnchorageTheme.typography.caption,
                        color = colors.textTertiary,
                    )
                }
            }
        }

        Spacer(Modifier.height(spacing.md))

        if (state.isCapturingOffice) {
            // The button is replaced rather than merely disabled: a spinner in
            // its place is unambiguous about *why* it cannot be pressed.
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
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
                    text = stringResource(R.string.attendance_capturing_office),
                    style = AnchorageTheme.typography.button,
                    color = colors.primary,
                )
            }
        } else {
            AnchorageOutlinedButton(
                text = stringResource(
                    if (anchor == null) R.string.attendance_set_office
                    else R.string.attendance_update_office,
                ),
                onClick = onSetOfficeLocation,
                enabled = !state.isBusy,
                leadingIcon = if (anchor == null) {
                    Icons.Outlined.AddCircleOutline
                } else {
                    Icons.Outlined.Refresh
                },
            )
        }
    }
}
