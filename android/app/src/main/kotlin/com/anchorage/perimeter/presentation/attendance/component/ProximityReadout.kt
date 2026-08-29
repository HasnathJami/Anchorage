package com.anchorage.perimeter.presentation.attendance.component

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.anchorage.perimeter.core.designsystem.component.DistanceDial
import com.anchorage.perimeter.core.designsystem.component.StatusPill
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.presentation.attendance.AttendanceFormatters
import com.anchorage.perimeter.presentation.attendance.AttendanceUiState
import com.anchorage.perimeter.presentation.attendance.ProximityUi
import com.anchorage.perimeter.R

/**
 * The centrepiece: distance dial, status pill and the sentence that tells the
 * user what to do about it.
 *
 * All three read from the same [ProximityUi] value, so they can never disagree
 * - a green ring above a red pill is impossible by construction.
 */
@Composable
fun ProximityReadout(
    state: AttendanceUiState,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing
    val reading = state.reading

    val isMarked = state.isAlreadyMarkedToday

    val arcColor = when {
        isMarked -> colors.successArc
        state.proximity == ProximityUi.InRange -> colors.successArc
        state.proximity == ProximityUi.LowConfidence -> colors.dialTrack
        state.proximity == ProximityUi.OutOfRange -> colors.dangerArc
        else -> colors.dialTrack
    }

    val fillColor = when {
        isMarked || state.proximity == ProximityUi.InRange -> colors.successDialFill
        state.proximity == ProximityUi.OutOfRange -> colors.dangerDialFill
        else -> colors.surface
    }

    // The arc is tweened over 450 ms because raw GPS jitters by a few metres a
    // second. The number in the middle of it was not, so the ring glided while
    // the read-out flickered 120 - 118 - 121 underneath it, which reads as a
    // broken sensor rather than a live one. Same duration and easing, so the
    // two move as one thing.
    //
    // Animating the *value* and formatting the result - rather than animating
    // an already-formatted string - is what keeps the "m" / "km" switch and
    // the locale's number format in one place.
    val animatedMeters by animateFloatAsState(
        targetValue = reading?.distanceMeters?.toFloat() ?: 0f,
        animationSpec = tween(durationMillis = 450, easing = FastOutSlowInEasing),
        label = "dial-distance",
    )

    val distanceLabel = if (reading != null) {
        AttendanceFormatters.distance(animatedMeters.toDouble())
    } else {
        stringResource(R.string.attendance_dial_unknown)
    }

    // The spoken value is the real one, not the frame the animation happens to
    // be on: a screen reader announcing "117 metres" mid-tween would be wrong.
    val spokenDistance = reading?.let { AttendanceFormatters.distance(it.distanceMeters) }
        ?: stringResource(R.string.attendance_dial_unknown)

    val captionLabel = when {
        reading != null -> stringResource(R.string.attendance_dial_away)
        // Ahead of the office check: with no permission there is nothing to
        // measure *from*, so "no office" would blame the wrong thing.
        !state.hasLocationPermission -> stringResource(R.string.attendance_dial_no_permission)
        state.anchor == null -> stringResource(R.string.attendance_dial_no_office)
        else -> stringResource(R.string.attendance_dial_locating)
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        DistanceDial(
            valueLabel = distanceLabel,
            captionLabel = captionLabel,
            progress = reading?.fenceProgress ?: 0f,
            arcColor = arcColor,
            fillColor = fillColor,
            contentDescription = reading
                ?.let { stringResource(R.string.attendance_dial_description, spokenDistance) }
                ?: stringResource(R.string.attendance_dial_description_unknown),
        )

        Spacer(Modifier.height(spacing.md))

        val (pillText, pillContainer, pillContent) = when {
            isMarked -> Triple(
                stringResource(R.string.attendance_status_checked_in),
                colors.successContainer,
                colors.successText,
            )

            state.anchor == null -> Triple(
                stringResource(R.string.attendance_status_no_office),
                colors.dangerContainer,
                colors.dangerText,
            )

            state.proximity == ProximityUi.InRange -> Triple(
                stringResource(R.string.attendance_status_in_range),
                colors.successContainer,
                colors.successText,
            )

            state.proximity == ProximityUi.OutOfRange -> Triple(
                stringResource(R.string.attendance_status_out_of_range),
                colors.dangerContainer,
                colors.dangerText,
            )

            state.proximity == ProximityUi.LowConfidence -> Triple(
                stringResource(R.string.attendance_status_low_confidence),
                colors.cautionContainer,
                colors.cautionText,
            )

            else -> Triple(
                stringResource(R.string.attendance_status_waiting),
                colors.primarySubtle,
                colors.primary,
            )
        }

        StatusPill(text = pillText, containerColor = pillContainer, contentColor = pillContent)

        Spacer(Modifier.height(spacing.sm))

        Text(
            text = helperText(state),
            style = AnchorageTheme.typography.caption,
            color = colors.textTertiary,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
    }
}

/** The one sentence that tells the user what to do next, per state. */
@Composable
private fun helperText(state: AttendanceUiState): String {
    val radius = GeofencePolicy.DEFAULT_RADIUS_METERS.toInt()
    val record = state.todayRecord

    return when {
        // The screen asks for permission with the system dialog on entry, so
        // this is not an offer - it is the explanation for an empty dial, and
        // it says how to get out of the state.
        !state.hasLocationPermission ->
            stringResource(R.string.attendance_helper_no_permission)

        record != null -> stringResource(
            R.string.attendance_helper_marked,
            AttendanceFormatters.clockTime(record.markedAtEpochMillis),
            AttendanceFormatters.distance(record.distanceMeters),
        )

        state.anchor == null -> stringResource(R.string.attendance_helper_no_office)

        state.proximity == ProximityUi.LowConfidence -> stringResource(
            R.string.attendance_helper_low_confidence,
            AttendanceFormatters.accuracy(state.reading?.accuracyMeters ?: 0f),
            radius,
        )

        state.proximity == ProximityUi.InRange -> stringResource(R.string.attendance_helper_in_range)

        state.proximity == ProximityUi.OutOfRange -> stringResource(
            R.string.attendance_helper_out_of_range,
            radius,
        )

        else -> stringResource(R.string.attendance_helper_waiting)
    }
}
