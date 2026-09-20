package com.anchorage.perimeter.presentation.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.anchorage.perimeter.presentation.attendance.AttendanceRoute
import com.anchorage.perimeter.presentation.history.AttendanceHistoryRoute
import com.anchorage.perimeter.presentation.officepicker.OfficePickerRoute

/**
 * The three screens' addresses, as string constants in one place.
 *
 * Compose Navigation matches routes by string, so a typo would be a runtime
 * crash rather than a compile error. Naming them here means the typo can only
 * be made once.
 */
object AnchorageDestinations {
    /** The main screen: the dial and the check-in button. */
    const val ATTENDANCE = "attendance"

    /** The log of past check-ins. */
    const val HISTORY = "attendance/history"

    /** The map for placing the office by hand. */
    const val OFFICE_PICKER = "attendance/office"
}

/**
 * **The whole navigation graph** — all three screens of the app.
 *
 * ```
 *              ┌──────────────┐
 *              │  Attendance  │  ← start destination
 *              └──┬────────┬──┘
 *        history  │        │  set office
 *                 ▼        ▼
 *          ┌─────────┐  ┌──────────────┐
 *          │ History │  │ OfficePicker │
 *          └─────────┘  └──────────────┘
 * ```
 *
 * Attendance is the start destination rather than a dashboard: the brief asks
 * for setup and check-in to live on one screen, so the app opens directly on
 * the thing the user came to do.
 *
 * @param onExitApp Called when the user confirms leaving. Wired to
 *   `finishAffinity` in [com.anchorage.perimeter.MainActivity].
 * @param navController The navigation controller. Defaulted so previews and
 *   tests can supply their own.
 */
@Composable
fun AnchorageNavHost(
    onExitApp: () -> Unit,
    navController: NavHostController = rememberNavController(),
) {
    NavHost(
        navController = navController,
        startDestination = AnchorageDestinations.ATTENDANCE,
    ) {
        composable(AnchorageDestinations.ATTENDANCE) {
            AttendanceRoute(
                // There is nothing behind the start destination. `popBackStack`
                // here was a no-op - it returns false on the start entry - so
                // the app bar's arrow did nothing at all. Leaving Attendance
                // means leaving the app, which the screen confirms first.
                onExitApp = onExitApp,
                onOpenHistory = { navController.navigate(AnchorageDestinations.HISTORY) },
                onPickOffice = { navController.navigate(AnchorageDestinations.OFFICE_PICKER) },
            )
        }

        composable(AnchorageDestinations.HISTORY) {
            AttendanceHistoryRoute(onBack = { navController.popBackStack() })
        }

        composable(AnchorageDestinations.OFFICE_PICKER) {
            OfficePickerRoute(
                onBack = { navController.popBackStack() },
                // No result is passed back. Attendance observes the anchor
                // repository, so the save propagates to it through the same
                // flow that feeds the dial - one source of truth, and no
                // savedStateHandle round-trip to keep in sync with it.
                onSaved = { navController.popBackStack() },
            )
        }
    }
}
