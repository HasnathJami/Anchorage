package com.anchorage.perimeter.presentation.officepicker

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.outlined.MyLocation
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.graphics.vector.ImageVector
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
        // The body runs to the bottom edge and [ConfirmBar] insets itself, so
        // the confirm surface - not the map, and not the mint background -
        // is what sits behind the system navigation bar.
        contentWindowInsets = WindowInsets(0),
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

                // Bottom-right of the map, exactly where a thumb rests. Zoom
                // sits above Find Me rather than beside it: the two are used
                // at different moments - Find Me once on arrival, zoom
                // repeatedly while framing the building - and stacking them
                // keeps the repeated one closest to the thumb.
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(spacing.sm),
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(spacing.md),
                ) {
                    ZoomControls(
                        zoom = state.zoom,
                        onZoomChanged = { onIntent(OfficePickerIntent.ZoomChanged(it)) },
                    )

                    FindMeButton(
                        isBusy = state.isLocating,
                        onClick = { onIntent(OfficePickerIntent.FindMeClicked) },
                    )
                }
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

/**
 * Zoom in and out, as buttons rather than pinch alone.
 *
 * Pinch is a two-handed gesture, and this screen is used one-handed while
 * standing outside a building - the other hand is holding something. The
 * buttons also make the zoom range *visible*: at 19 the plus greys out, so a
 * user pinching fruitlessly at maximum detail can tell the map has stopped
 * rather than assuming it is broken.
 *
 * One pill with a hairline between the halves, not two circles: they act on
 * the same axis of one property, and separating them reads as two unrelated
 * controls.
 */
@Composable
private fun ZoomControls(
    zoom: Int,
    onZoomChanged: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val canZoomIn = zoom < OfficePickerUiState.MAX_ZOOM
    val canZoomOut = zoom > OfficePickerUiState.MIN_ZOOM

    Surface(
        modifier = modifier.width(48.dp),
        shape = AnchorageTheme.shapes.button,
        color = colors.surface,
        shadowElevation = 3.dp,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            ZoomButton(
                icon = Icons.Filled.Add,
                contentDescription = stringResource(R.string.picker_zoom_in),
                enabled = canZoomIn,
                onClick = { onZoomChanged(zoom + 1) },
            )

            HorizontalDivider(
                modifier = Modifier.width(24.dp),
                color = colors.outlineSubtle,
            )

            ZoomButton(
                icon = Icons.Filled.Remove,
                contentDescription = stringResource(R.string.picker_zoom_out),
                enabled = canZoomOut,
                onClick = { onZoomChanged(zoom - 1) },
            )
        }
    }
}

@Composable
private fun ZoomButton(
    icon: ImageVector,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = AnchorageTheme.colors
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(48.dp)) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            // Greyed rather than hidden: a control that vanishes at the end of
            // its range leaves the user wondering where it went.
            tint = if (enabled) colors.primary else colors.textTertiary,
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
 * The chosen coordinates and the confirm button. Nothing else.
 *
 * There is deliberately no "you are N m from this point" read-out. The picker
 * places an office; it does not audit where the user is standing while they
 * place it, and a sentence saying "outside the 50 m perimeter" beside a button
 * that saves anyway reads as a warning about a rule that is not being applied.
 * The real comparison - current position against the saved anchor - happens on
 * the Attendance screen, where it decides something.
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
                // The inset lives here, inside the Surface, rather than on the
                // Scaffold's content. Both keep the button clear of the system
                // bar, but only this one lets the Surface *paint* that strip -
                // so the navigation bar matches the confirm bar instead of
                // showing the map sliding past underneath it.
                //
                // Exactly one of the two applies it: the Scaffold's own inset
                // is switched off above. Insetting in both places is what
                // stranded the button a full nav-bar height off the edge.
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = spacing.md, vertical = spacing.md),
            verticalArrangement = Arrangement.spacedBy(spacing.sm),
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
