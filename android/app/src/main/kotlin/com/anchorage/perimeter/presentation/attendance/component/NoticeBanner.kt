package com.anchorage.perimeter.presentation.attendance.component

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.GpsOff
import androidx.compose.material.icons.outlined.LocationDisabled
import androidx.compose.material.icons.outlined.LocationOff
import androidx.compose.material.icons.outlined.SdCardAlert
import androidx.compose.material.icons.outlined.Straighten
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.anchorage.perimeter.core.designsystem.component.AnchorageBanner
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.presentation.attendance.AttendanceFormatters
import com.anchorage.perimeter.presentation.attendance.AttendanceNotice
import com.anchorage.perimeter.R

/**
 * Renders an [AttendanceNotice] as a banner with a matching remedy.
 *
 * Every branch supplies its own icon, tone and action verb. The `when` is
 * exhaustive over a sealed type, so adding a new failure mode to the domain
 * will not compile until someone has decided how to explain it to a user -
 * which is exactly the pressure you want on that decision.
 */
@Composable
fun NoticeBanner(
    notice: AttendanceNotice?,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors

    val descriptor = when (notice) {
        AttendanceNotice.PermissionBlocked -> NoticeDescriptor(
            title = stringResource(R.string.notice_permission_blocked_title),
            message = stringResource(R.string.notice_permission_blocked_body),
            action = stringResource(R.string.notice_permission_blocked_action),
            icon = Icons.Outlined.LocationDisabled,
            container = colors.dangerContainer,
            content = colors.dangerText,
        )

        AttendanceNotice.LocationServicesOff -> NoticeDescriptor(
            title = stringResource(R.string.notice_services_off_title),
            message = stringResource(R.string.notice_services_off_body),
            action = stringResource(R.string.notice_services_off_action),
            icon = Icons.Outlined.GpsOff,
            container = colors.cautionContainer,
            content = colors.cautionText,
        )

        is AttendanceNotice.WeakSignal -> NoticeDescriptor(
            title = stringResource(R.string.notice_weak_signal_title),
            message = stringResource(
                R.string.notice_weak_signal_body,
                AttendanceFormatters.accuracy(notice.accuracyMeters),
            ),
            action = stringResource(R.string.notice_weak_signal_action),
            icon = Icons.Outlined.Straighten,
            container = colors.cautionContainer,
            content = colors.cautionText,
        )

        is AttendanceNotice.AnchorRejected -> NoticeDescriptor(
            title = stringResource(R.string.notice_anchor_rejected_title),
            message = stringResource(
                R.string.notice_anchor_rejected_body,
                AttendanceFormatters.accuracy(notice.reportedAccuracyMeters),
                AttendanceFormatters.accuracy(notice.requiredAccuracyMeters),
            ),
            action = stringResource(R.string.notice_anchor_rejected_action),
            icon = Icons.Outlined.Straighten,
            container = colors.cautionContainer,
            content = colors.cautionText,
        )

        AttendanceNotice.StorageProblem -> NoticeDescriptor(
            title = stringResource(R.string.notice_storage_title),
            message = stringResource(R.string.notice_storage_body),
            action = stringResource(R.string.notice_storage_action),
            icon = Icons.Outlined.SdCardAlert,
            container = colors.dangerContainer,
            content = colors.dangerText,
        )

        AttendanceNotice.MockLocationActive -> NoticeDescriptor(
            title = stringResource(R.string.notice_mock_location_title),
            message = stringResource(R.string.notice_mock_location_body),
            action = stringResource(R.string.notice_mock_location_action),
            icon = Icons.Outlined.Warning,
            container = colors.cautionContainer,
            content = colors.cautionText,
        )

        null -> null
    }

    AnchorageBanner(
        visible = descriptor != null,
        title = descriptor?.title.orEmpty(),
        message = descriptor?.message.orEmpty(),
        icon = descriptor?.icon ?: Icons.Outlined.ErrorOutline,
        containerColor = descriptor?.container ?: colors.cautionContainer,
        contentColor = descriptor?.content ?: colors.cautionText,
        actionLabel = descriptor?.action,
        onAction = onAction,
        modifier = modifier,
    )

    if (descriptor != null) {
        Spacer(Modifier.height(AnchorageTheme.spacing.sm))
    }
}

private data class NoticeDescriptor(
    val title: String,
    val message: String,
    val action: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val container: androidx.compose.ui.graphics.Color,
    val content: androidx.compose.ui.graphics.Color,
)
