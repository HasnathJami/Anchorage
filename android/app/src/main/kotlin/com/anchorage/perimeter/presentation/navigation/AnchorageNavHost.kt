package com.anchorage.perimeter.presentation.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.anchorage.perimeter.presentation.attendance.AttendanceRoute
import com.anchorage.perimeter.presentation.history.AttendanceHistoryRoute
import com.anchorage.perimeter.presentation.officepicker.OfficePickerRoute

/** Type-safe-ish route keys; string constants kept in one place. */
object AnchorageDestinations {
    const val ATTENDANCE = "attendance"
    const val HISTORY = "attendance/history"
    const val OFFICE_PICKER = "attendance/office"
}

/**
 * The whole navigation graph.
 *
 * Attendance is the start destination rather than a dashboard: the brief asks
 * for setup and check-in to live on one screen, so the app opens directly on
 * the thing the user came to do.
 */
@Composable
fun AnchorageNavHost(
    navController: NavHostController = rememberNavController(),
) {
    NavHost(
        navController = navController,
        startDestination = AnchorageDestinations.ATTENDANCE,
    ) {
        composable(AnchorageDestinations.ATTENDANCE) {
            AttendanceRoute(
                // There is nothing behind the start destination, so "back"
                // finishes the task rather than popping to an empty stack.
                onBack = { navController.popBackStack() },
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
