package com.anchorage.perimeter.presentation.officepicker

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.outlined.MyLocation
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner as ComposeLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.anchorage.perimeter.R
import com.anchorage.perimeter.core.designsystem.component.AnchoragePrimaryButton
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.presentation.attendance.AttendanceFormatters
import com.anchorage.perimeter.presentation.common.hasLocationPermission
import com.anchorage.perimeter.presentation.common.openAppSettings
import com.anchorage.perimeter.presentation.common.openLocationSettings
import com.anchorage.perimeter.presentation.common.shouldShowLocationRationale
import com.anchorage.perimeter.presentation.officepicker.component.MapCanvas
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * "Set Office Location" as a map, rather than as a single blind GPS grab.
 *
 * The screen exists because capturing the raw fix has one failure mode the
 * user cannot see or correct: if the phone is 30 m out, the office is 30 m out
 * *forever*, and every future check-in inherits the error. Here the fix is a
 * starting suggestion and the user gets the final say - they can see the
 * building, drag the perimeter over it, and confirm.
 */
@Composable
fun OfficePickerRoute(
    onBack: () -> Unit,
    onSaved: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: OfficePickerViewModel = hiltViewModel(),
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val lifecycleOwner = ComposeLifecycleOwner.current

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        viewModel.onIntent(
            OfficePickerIntent.PermissionResult(
                granted = grants[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                    grants[Manifest.permission.ACCESS_COARSE_LOCATION] == true,
                canAskAgain = context.shouldShowLocationRationale(),
            ),
        )
    }

    LaunchedEffect(viewModel) { viewModel.onIntent(OfficePickerIntent.ScreenStarted) }

    // Re-checked on every resume so granting permission (or switching location
    // on) in Settings and swiping back recovers the screen with no extra tap.
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            viewModel.onIntent(
                OfficePickerIntent.PermissionStateChanged(context.hasLocationPermission()),
            )
        }
    }

    LaunchedEffect(viewModel) {
        viewModel.effects.collectLatest { effect ->
            when (effect) {
                OfficePickerEffect.RequestLocationPermission -> permissionLauncher.launch(
                    arrayOf(
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ),
                )

                OfficePickerEffect.OpenAppSettings -> context.openAppSettings()
                OfficePickerEffect.OpenLocationSettings -> context.openLocationSettings()
                is OfficePickerEffect.Saved -> onSaved()
                is OfficePickerEffect.ShowMessage -> scope.launch {
                    snackbarHostState.showSnackbar(
                        when (effect.reason) {
                            PickerMessage.Saved ->
                                context.getString(R.string.picker_message_saved)

                            PickerMessage.NothingToSave ->
                                context.getString(R.string.picker_message_nothing_to_save)

                            PickerMessage.Unknown -> context.getString(R.string.message_unknown)
                        },
                    )
                }
            }
        }
    }

    OfficePickerContent(
        state = uiState,
        attribution = viewModel.attribution,
        snackbarHostState = snackbarHostState,
        onBack = onBack,
        onIntent = viewModel::onIntent,
        modifier = modifier,
    )
}

/**
 * The stateless body: data in, callbacks out, so it previews and can be driven
 * by an instrumentation test without Hilt, GPS or a network.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun OfficePickerContent(
    state: OfficePickerUiState,
    attribution: String,
    snackbarHostState: SnackbarHostState,
    onBack: () -> Unit,
    onIntent: (OfficePickerIntent) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing

    Scaffold(
        modifier = modifier,
        containerColor = colors.backgroundTop,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = stringResource(R.string.picker_title),
                        style = AnchorageTheme.typography.screenTitle,
                        color = colors.primary,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            contentDescription = stringResource(R.string.attendance_back),
                            tint = colors.primary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.topBarSurface,
                ),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                MapCanvas(
                    centre = state.centre,
                    zoom = state.zoom,
                    userLocation = state.userLocation,
                    radiusMeters = state.radiusMeters,
                    isUserInsidePerimeter = state.isUserInsidePerimeter,
                    tiles = state.tiles,
                    onCentreMoved = { onIntent(OfficePickerIntent.CentreMoved(it)) },
                    onZoomChanged = { onIntent(OfficePickerIntent.ZoomChanged(it)) },
                    onTilesRequested = { onIntent(OfficePickerIntent.TilesRequested(it)) },
                    minZoom = OfficePickerUiState.MIN_ZOOM,
                    maxZoom = OfficePickerUiState.MAX_ZOOM,
                    modifier = Modifier.fillMaxSize(),
                )

                if (state.isMapImageryDegraded) {
                    MapOfflineChip(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .padding(top = spacing.sm),
                    )
                }

                Text(
                    text = attribution,
                    style = AnchorageTheme.typography.caption,
                    color = colors.textTertiary,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(spacing.xs),
                )

                // Bottom-right of the map, exactly where a thumb rests.
                FindMeButton(
                    isBusy = state.isLocating,
                    onClick = { onIntent(OfficePickerIntent.FindMeClicked) },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(spacing.md),
                )
            }

            ConfirmBar(state = state, onIntent = onIntent)
        }

        state.notice?.let { notice ->
            PickerDialog(
                notice = notice,
                onAction = { onIntent(OfficePickerIntent.NoticeActionClicked) },
                onDismiss = { onIntent(OfficePickerIntent.NoticeDismissed) },
            )
        }
    }
}

@Composable
private fun MapOfflineChip(modifier: Modifier = Modifier) {
    val colors = AnchorageTheme.colors
    Surface(
        modifier = modifier,
        shape = AnchorageTheme.shapes.pill,
        color = colors.cautionContainer,
    ) {
        Text(
            text = stringResource(R.string.picker_map_offline_chip),
            style = AnchorageTheme.typography.caption,
            color = colors.cautionText,
            modifier = Modifier.padding(
                horizontal = AnchorageTheme.spacing.sm,
                vertical = AnchorageTheme.spacing.xxs,
            ),
        )
    }
}

@Composable
private fun FindMeButton(
    isBusy: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    Surface(
        modifier = modifier
            .size(48.dp)
            .clip(CircleShape),
        shape = CircleShape,
        color = colors.surface,
        shadowElevation = 3.dp,
    ) {
        IconButton(onClick = onClick, enabled = !isBusy) {
            if (isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                    color = colors.primary,
                )
            } else {
                Icon(
                    imageVector = Icons.Outlined.MyLocation,
                    contentDescription = stringResource(R.string.picker_find_me),
                    tint = colors.primary,
                )
            }
        }
    }
}

/**
 * Coordinates, the live distance read-out and the confirm button.
 *
 * The distance sentence is what stops the ring's colour from being the only
 * carrier of state - the accessibility rule the rest of the app already obeys.
 */
@Composable
private fun ConfirmBar(
    state: OfficePickerUiState,
    onIntent: (OfficePickerIntent) -> Unit,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing

    Surface(color = colors.surface, shadowElevation = 8.dp) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = spacing.md, vertical = spacing.md),
            verticalArrangement = Arrangement.spacedBy(spacing.xs),
        ) {
            Text(
                text = stringResource(
                    R.string.attendance_coordinates,
                    AttendanceFormatters.coordinate(state.centre.latitude),
                    AttendanceFormatters.coordinate(state.centre.longitude),
                ),
                style = AnchorageTheme.typography.coordinate,
                color = colors.textPrimary,
            )

            Text(
                text = perimeterSentence(state),
                style = AnchorageTheme.typography.body,
                color = when (state.isUserInsidePerimeter) {
                    true -> colors.successText
                    false -> colors.dangerText
                    null -> colors.textSecondary
                },
            )

            Spacer(Modifier.width(spacing.xxs))

            AnchoragePrimaryButton(
                text = stringResource(
                    if (state.hasExistingAnchor) R.string.picker_confirm_update
                    else R.string.picker_confirm_set,
                ),
                onClick = { onIntent(OfficePickerIntent.ConfirmClicked) },
                enabled = state.canConfirm,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics {
                        contentDescription = if (state.canConfirm) "" else "Move the map first"
                    },
            )
        }
    }
}

@Composable
private fun perimeterSentence(state: OfficePickerUiState): String {
    val distance = state.distanceFromUserMeters
    return when {
        distance == null -> stringResource(R.string.picker_distance_unknown)
        state.isUserInsidePerimeter == true -> stringResource(
            R.string.picker_distance_inside,
            AttendanceFormatters.distance(distance),
            state.radiusMeters.toInt(),
        )

        else -> stringResource(
            R.string.picker_distance_outside,
            AttendanceFormatters.distance(distance),
            state.radiusMeters.toInt(),
        )
    }
}

/**
 * One dialog, one remedy.
 *
 * Every case here is recoverable, so every case has an action that actually
 * recovers it rather than an "OK" that dismisses the problem and changes
 * nothing.
 */
@Composable
private fun PickerDialog(
    notice: PickerNotice,
    onAction: () -> Unit,
    onDismiss: () -> Unit,
) {
    val (titleRes, bodyRes, actionRes) = when (notice) {
        PickerNotice.PermissionRequired -> Triple(
            R.string.notice_permission_required_title,
            R.string.notice_permission_required_body,
            R.string.notice_permission_required_action,
        )

        PickerNotice.PermissionBlocked -> Triple(
            R.string.notice_permission_blocked_title,
            R.string.notice_permission_blocked_body,
            R.string.notice_permission_blocked_action,
        )

        PickerNotice.ServicesDisabled -> Triple(
            R.string.notice_services_off_title,
            R.string.notice_services_off_body,
            R.string.notice_services_off_action,
        )

        PickerNotice.PositionUnavailable -> Triple(
            R.string.notice_position_unavailable_title,
            R.string.notice_position_unavailable_body,
            R.string.notice_position_unavailable_action,
        )

        PickerNotice.LocationTimeout -> Triple(
            R.string.picker_notice_timeout_title,
            R.string.picker_notice_timeout_body,
            R.string.notice_position_unavailable_action,
        )

        PickerNotice.MapImageryUnavailable -> Triple(
            R.string.picker_notice_offline_title,
            R.string.picker_notice_offline_body,
            R.string.picker_notice_offline_action,
        )

        PickerNotice.SaveFailed -> Triple(
            R.string.picker_notice_save_failed_title,
            R.string.picker_notice_save_failed_body,
            R.string.notice_storage_action,
        )
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = stringResource(titleRes),
                style = AnchorageTheme.typography.body.copy(fontWeight = FontWeight.SemiBold),
                color = AnchorageTheme.colors.textPrimary,
            )
        },
        text = {
            Text(
                text = stringResource(bodyRes),
                style = AnchorageTheme.typography.body,
                color = AnchorageTheme.colors.textSecondary,
                textAlign = TextAlign.Start,
            )
        },
        confirmButton = {
            TextButton(onClick = onAction) {
                Text(
                    text = stringResource(actionRes),
                    color = AnchorageTheme.colors.primary,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(
                    text = stringResource(R.string.picker_dismiss),
                    color = AnchorageTheme.colors.textSecondary,
                )
            }
        },
        containerColor = AnchorageTheme.colors.surface,
        shape = AnchorageTheme.shapes.card,
    )
}
