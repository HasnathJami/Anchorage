package com.anchorage.perimeter.presentation.attendance

import androidx.compose.material3.SnackbarHostState
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.GeofenceReading
import com.anchorage.perimeter.domain.policy.ProximityStatus
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumentation tests for the stateless screen body.
 *
 * They assert the contract that matters to a user: the check-in button is
 * pressable exactly when the state says it should be, and the screen explains
 * itself when it is not. Because [AttendanceContent] takes plain data, none of
 * this needs Hilt, a fake GPS or a granted permission.
 *
 * Run with: ./gradlew :feature:attendance:connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class AttendanceContentTest {

    @get:Rule
    val composeRule = createComposeRule()

    private val anchor = OfficeAnchor(
        point = GeoPoint(23.780887, 90.414391),
        accuracyMeters = 5f,
        capturedAtEpochMillis = 1_756_000_000_000L,
    )

    private fun reading(distance: Double, inside: Boolean) = GeofenceReading(
        distanceMeters = distance,
        radiusMeters = GeofencePolicy.DEFAULT_RADIUS_METERS,
        status = if (inside) ProximityStatus.INSIDE else ProximityStatus.OUTSIDE,
        accuracyMeters = 6f,
        isConfident = true,
        fixTimestampEpochMillis = 1_756_000_000_000L,
    )

    private fun setContent(
        state: AttendanceUiState,
        onIntent: (AttendanceIntent) -> Unit = {},
    ) {
        composeRule.setContent {
            AnchorageTheme {
                AttendanceContent(
                    state = state,
                    snackbarHostState = SnackbarHostState(),
                    onBack = {},
                    onOpenHistory = {},
                    onIntent = onIntent,
                )
            }
        }
    }

    @Test
    fun outOfRange_showsDistanceAndKeepsCheckInDisabled() {
        setContent(
            AttendanceUiState(
                isBootstrapping = false,
                anchor = anchor,
                reading = reading(120.0, inside = false),
                proximity = ProximityUi.OutOfRange,
                isWindowOpen = true,
                windowLabel = "09:00 AM - 10:30 AM",
                canMarkAttendance = false,
            ),
        )

        composeRule.onNodeWithText("120m").assertExists()
        composeRule.onNodeWithText("OUT OF RANGE").assertExists()
        composeRule.onNodeWithText("Mark Attendance").assertIsNotEnabled()
    }

    @Test
    fun inRange_enablesCheckIn() {
        setContent(
            AttendanceUiState(
                isBootstrapping = false,
                anchor = anchor,
                reading = reading(12.0, inside = true),
                proximity = ProximityUi.InRange,
                isWindowOpen = true,
                windowLabel = "09:00 AM - 10:30 AM",
                canMarkAttendance = true,
            ),
        )

        composeRule.onNodeWithText("IN RANGE").assertExists()
        composeRule.onNodeWithText("Mark Attendance").assertIsEnabled()
    }

    @Test
    fun tappingMarkAttendance_emitsTheIntent() {
        var received: AttendanceIntent? = null
        setContent(
            state = AttendanceUiState(
                isBootstrapping = false,
                anchor = anchor,
                reading = reading(12.0, inside = true),
                proximity = ProximityUi.InRange,
                isWindowOpen = true,
                windowLabel = "09:00 AM - 10:30 AM",
                canMarkAttendance = true,
            ),
            onIntent = { received = it },
        )

        composeRule.onNodeWithText("Mark Attendance").performClick()

        assert(received == AttendanceIntent.MarkAttendanceClicked)
    }

    @Test
    fun noOfficeYet_offersToSetOneAndExplainsWhyTheDialIsEmpty() {
        setContent(
            AttendanceUiState(
                isBootstrapping = false,
                windowLabel = "09:00 AM - 10:30 AM",
            ),
        )

        composeRule.onNodeWithText("Set Office Location").assertIsEnabled()
        composeRule.onNodeWithText("OFFICE NOT SET").assertExists()
        composeRule.onNodeWithText("Mark Attendance").assertIsNotEnabled()
    }

    @Test
    fun permissionBanner_offersTheGrantAction() {
        var received: AttendanceIntent? = null
        setContent(
            state = AttendanceUiState(
                isBootstrapping = false,
                windowLabel = "09:00 AM - 10:30 AM",
                notice = AttendanceNotice.PermissionRequired,
            ),
            onIntent = { received = it },
        )

        composeRule.onNodeWithText("Location permission needed").assertExists()
        composeRule.onNodeWithText("Grant permission").performClick()

        assert(received == AttendanceIntent.NoticeActionClicked)
    }
}
