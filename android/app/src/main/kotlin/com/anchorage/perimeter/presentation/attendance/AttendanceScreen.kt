package com.anchorage.perimeter.presentation.attendance

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner as ComposeLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.anchorage.perimeter.R
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.GeofenceReading
import com.anchorage.perimeter.domain.policy.ProximityStatus
import com.anchorage.perimeter.presentation.attendance.component.CheckInPanel
import com.anchorage.perimeter.presentation.attendance.component.NoticeBanner
import com.anchorage.perimeter.presentation.attendance.component.OfficeContextCard
import com.anchorage.perimeter.presentation.attendance.component.ProximityReadout
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Route-level composable: owns the ViewModel, the runtime-permission dance and
 * the effect plumbing, then hands a plain state object to [AttendanceContent].
 *
 * Splitting the screen this way is what makes the visual layer previewable and
 * screenshot-testable: [AttendanceContent] has no Hilt, no permissions and no
 * coroutines - only data in, callbacks out.
 */
@Composable
fun AttendanceRoute(
    onBack: () -> Unit,
    onOpenHistory: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: AttendanceViewModel = hiltViewModel(),
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val lifecycleOwner = ComposeLifecycleOwner.current

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        val granted = grants[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            grants[Manifest.permission.ACCESS_COARSE_LOCATION] == true

        // `false` from the launcher means either "denied once" or "blocked
        // forever". The activity's rationale flag is the only way to tell them
        // apart, and it must be read *after* the dialog closes.
        viewModel.onIntent(
            AttendanceIntent.PermissionResult(
                granted = granted,
                canAskAgain = context.shouldShowLocationRationale(),
            ),
        )
    }

    // Re-checking on every resume is what makes the screen recover silently
    // when the user grants permission (or switches location on) in Settings
    // and swipes back.
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            viewModel.onIntent(
                AttendanceIntent.PermissionStateChanged(context.hasLocationPermission()),
            )
        }
    }

    LaunchedEffect(viewModel) {
        viewModel.effects.collectLatest { effect ->
            when (effect) {
                AttendanceEffect.RequestLocationPermission -> permissionLauncher.launch(
                    arrayOf(
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ),
                )

                AttendanceEffect.OpenAppSettings -> context.openAppSettings()
                AttendanceEffect.OpenLocationSettings -> context.openLocationSettings()

                is AttendanceEffect.OfficeAnchored -> scope.launch {
                    snackbarHostState.showSnackbar(
                        context.getString(
                            R.string.message_office_anchored,
                            AttendanceFormatters.accuracy(effect.accuracyMeters),
                        ),
                    )
                }

                is AttendanceEffect.AttendanceMarked -> scope.launch {
                    snackbarHostState.showSnackbar(
                        context.getString(
                            R.string.message_attendance_marked,
                            AttendanceFormatters.clockTime(effect.record.markedAtEpochMillis),
                        ),
                    )
                }

                is AttendanceEffect.ShowMessage -> scope.launch {
                    snackbarHostState.showSnackbar(
                        context.messageFor(effect.reason, uiState.windowLabel),
                    )
                }
            }
        }
    }

    AttendanceContent(
        state = uiState,
        snackbarHostState = snackbarHostState,
        onBack = onBack,
        onOpenHistory = onOpenHistory,
        onIntent = viewModel::onIntent,
        modifier = modifier,
    )
}

/**
 * The stateless screen body.
 *
 * The vertical rhythm here is a direct transcription of the reference design:
 * a white app bar, then the office card, then the proximity read-out, then the
 * dashed check-in panel, over a soft mint gradient.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun AttendanceContent(
    state: AttendanceUiState,
    snackbarHostState: SnackbarHostState,
    onBack: () -> Unit,
    onOpenHistory: () -> Unit,
    onIntent: (AttendanceIntent) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AnchorageTheme.colors
    val spacing = AnchorageTheme.spacing

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = colors.backgroundTop,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = stringResource(R.string.attendance_title),
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
                            modifier = Modifier.size(28.dp),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onOpenHistory) {
                        Icon(
                            imageVector = Icons.Outlined.History,
                            contentDescription = stringResource(R.string.attendance_history),
                            tint = colors.primary,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.topBarSurface,
                    titleContentColor = colors.primary,
                ),
            )
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(
                    Brush.verticalGradient(
                        listOf(colors.backgroundTop, colors.backgroundBottom),
                    ),
                ),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(
                        PaddingValues(
                            start = spacing.screenHorizontal,
                            end = spacing.screenHorizontal,
                            top = spacing.sm,
                            bottom = spacing.xl,
                        ),
                    ),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                NoticeBanner(
                    notice = state.notice,
                    onAction = { onIntent(AttendanceIntent.NoticeActionClicked) },
                )

                OfficeContextCard(
                    state = state,
                    onSetOfficeLocation = { onIntent(AttendanceIntent.SetOfficeLocationClicked) },
                    onClearOffice = { onIntent(AttendanceIntent.ClearOfficeClicked) },
                )

                Spacer(Modifier.height(spacing.xl))

                ProximityReadout(state = state)

                Spacer(Modifier.height(spacing.xl))

                CheckInPanel(
                    state = state,
                    onMarkAttendance = { onIntent(AttendanceIntent.MarkAttendanceClicked) },
                )
            }
        }
    }
}

// --------------------------------------------------------------- platform glue

private fun Context.hasLocationPermission(): Boolean =
    androidx.core.content.ContextCompat.checkSelfPermission(
        this,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED ||
        androidx.core.content.ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

/**
 * True while Android is still willing to show the permission dialog.
 *
 * The flag lives on Activity, so this walks the ContextWrapper chain rather
 * than assuming the composition's context is one - which it is not when the
 * screen is hosted inside a `ComposeView`.
 */
private fun Context.shouldShowLocationRationale(): Boolean {
    val activity = generateSequence(this) { (it as? android.content.ContextWrapper)?.baseContext }
        .filterIsInstance<android.app.Activity>()
        .firstOrNull() ?: return true

    return androidx.core.app.ActivityCompat.shouldShowRequestPermissionRationale(
        activity,
        Manifest.permission.ACCESS_FINE_LOCATION,
    )
}

private fun Context.openAppSettings() {
    startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

private fun Context.openLocationSettings() {
    startActivity(
        Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
    )
}

private fun Context.messageFor(reason: FailureReason, windowLabel: String): String = when (reason) {
    FailureReason.OutsideGeofence -> getString(R.string.message_outside_geofence)
    FailureReason.WindowClosed -> getString(R.string.message_window_closed, windowLabel)
    FailureReason.AlreadyMarkedToday -> getString(R.string.message_already_marked)
    FailureReason.OfficeNotConfigured -> getString(R.string.message_office_not_configured)
    FailureReason.LocationTimeout -> getString(R.string.message_location_timeout)
    FailureReason.Unknown -> getString(R.string.message_unknown)
}

// -------------------------------------------------------------------- previews

private val previewAnchor = OfficeAnchor(
    point = GeoPoint(23.780887, 90.414391),
    accuracyMeters = 5f,
    capturedAtEpochMillis = 1_756_000_000_000L,
)

private fun previewReading(distance: Double, inside: Boolean) = GeofenceReading(
    distanceMeters = distance,
    radiusMeters = GeofencePolicy.DEFAULT_RADIUS_METERS,
    status = if (inside) ProximityStatus.INSIDE else ProximityStatus.OUTSIDE,
    accuracyMeters = 6f,
    isConfident = true,
    fixTimestampEpochMillis = 1_756_000_000_000L,
)

@Preview(name = "Out of range", showBackground = true, heightDp = 900)
@Composable
private fun AttendanceOutOfRangePreview() {
    AnchorageTheme {
        AttendanceContent(
            state = AttendanceUiState(
                isBootstrapping = false,
                anchor = previewAnchor,
                reading = previewReading(120.0, inside = false),
                proximity = ProximityUi.OutOfRange,
                isWindowOpen = true,
                windowLabel = "09:00 AM - 10:30 AM",
                canMarkAttendance = false,
            ),
            snackbarHostState = SnackbarHostState(),
            onBack = {},
            onOpenHistory = {},
            onIntent = {},
        )
    }
}

@Preview(name = "In range", showBackground = true, heightDp = 900)
@Composable
private fun AttendanceInRangePreview() {
    AnchorageTheme {
        AttendanceContent(
            state = AttendanceUiState(
                isBootstrapping = false,
                anchor = previewAnchor,
                reading = previewReading(12.0, inside = true),
                proximity = ProximityUi.InRange,
                isWindowOpen = true,
                windowLabel = "09:00 AM - 10:30 AM",
                canMarkAttendance = true,
            ),
            snackbarHostState = SnackbarHostState(),
            onBack = {},
            onOpenHistory = {},
            onIntent = {},
        )
    }
}

@Preview(name = "No office yet", showBackground = true, heightDp = 900)
@Composable
private fun AttendanceNoOfficePreview() {
    AnchorageTheme {
        AttendanceContent(
            state = AttendanceUiState(
                isBootstrapping = false,
                windowLabel = "09:00 AM - 10:30 AM",
                notice = AttendanceNotice.PermissionRequired,
            ),
            snackbarHostState = SnackbarHostState(),
            onBack = {},
            onOpenHistory = {},
            onIntent = {},
        )
    }
}
