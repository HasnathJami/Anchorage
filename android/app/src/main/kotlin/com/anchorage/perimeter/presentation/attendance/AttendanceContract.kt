package com.anchorage.perimeter.presentation.attendance

import androidx.compose.runtime.Immutable
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.GeofenceReading

/**
 * The MVI contract for the Attendance screen.
 *
 * Three separate types, three separate jobs:
 *
 *  * [AttendanceUiState] - everything that is *true right now*. Rendered
 *    declaratively; replaying it always reproduces the same pixels.
 *  * [AttendanceIntent] - everything the user can *do*. The screen sends these
 *    and nothing else, so the ViewModel's public surface is one function.
 *  * [AttendanceEffect] - the one-shot things that must happen *once*
 *    (navigate, launch the permission dialog, show a snackbar). Keeping these
 *    out of the state is what stops a snackbar reappearing after every screen
 *    rotation - the classic bug of stuffing events into state.
 *
 * Note that the state holds *domain* values (metres, timestamps, enums) rather
 * than formatted strings. Formatting belongs to the composable that knows the
 * locale and the available width; keeping it out of here means the ViewModel
 * tests never need a Context.
 */
@Immutable
data class AttendanceUiState(
    /** True until the first status emission lands; drives the skeleton. */
    val isBootstrapping: Boolean = true,

    val anchor: OfficeAnchor? = null,
    val reading: GeofenceReading? = null,
    val todayRecord: AttendanceRecord? = null,

    val proximity: ProximityUi = ProximityUi.Unknown,
    val isWindowOpen: Boolean = false,
    val windowLabel: String = "",

    val isCapturingOffice: Boolean = false,
    val isMarkingAttendance: Boolean = false,

    /** The persistent problem banner, or `null` when nothing is wrong. */
    val notice: AttendanceNotice? = null,

    val canMarkAttendance: Boolean = false,

    /**
     * False once the user has been asked and has said no.
     *
     * Not a banner. The screen asks with the *system* dialog on entry, so the
     * only thing left to say afterwards is why the dial is empty - and that
     * belongs in the caption under it, next to the thing it explains, rather
     * than in a panel at the top of the screen repeating an offer the user has
     * already declined.
     */
    val hasLocationPermission: Boolean = true,
) {
    val isOfficeConfigured: Boolean get() = anchor != null

    val isAlreadyMarkedToday: Boolean get() = todayRecord != null

    /** True while either long-running action is in flight. */
    val isBusy: Boolean get() = isCapturingOffice || isMarkingAttendance
}

/** How the dial and status pill should read. */
enum class ProximityUi {
    /** No anchor yet, or no fix yet. */
    Unknown,

    /** Inside the fence with a trustworthy fix. */
    InRange,

    /** Outside the fence. */
    OutOfRange,

    /**
     * Position looks close but its error radius is too wide to act on. A
     * distinct state rather than a flavour of [OutOfRange], because the user's
     * remedy is different: wait or step outside, not walk closer.
     */
    LowConfidence,
}

/**
 * A persistent condition worth a banner.
 *
 * Modelled as data - not a pre-baked string - so the same notice can render as
 * a full banner on the screen and as a terse content description for
 * TalkBack without the two drifting apart.
 */
sealed interface AttendanceNotice {

    /** Permission not granted yet, and the system dialog can still be shown. */
    // `PermissionRequired` used to live here.
    //
    // It was a banner that said "Location permission needed" over a button
    // that opened the system dialog - an in-app dialog whose only job was to
    // summon the real one. The screen now asks directly on entry, which is one
    // fewer tap in the common case and one fewer thing to read. What survives
    // is [PermissionBlocked], and only because the system dialog genuinely
    // cannot help there: Android will not show it again, so Settings is the
    // only route and an app that does not offer it is a dead end.

    /** Permission denied permanently; only app settings can fix it. */
    data object PermissionBlocked : AttendanceNotice

    /** Permission granted but the device location toggle is off. */
    data object LocationServicesOff : AttendanceNotice

    /** Fixes are arriving but are too imprecise to gate a check-in on. */
    data class WeakSignal(val accuracyMeters: Float) : AttendanceNotice

    /** The positioning stack produced nothing usable. */
    // `PositionUnavailable` used to live here, with a Retry action.
    //
    // It was removed because it had nothing to offer. The dial keeps showing
    // the last known distance through a dropout, and the stream recovers on
    // its own when the provider comes back - so the banner interrupted a
    // screen that was still telling the truth, to offer a button that did
    // what was already happening. A momentary condition with no distinct
    // remedy is not a notice; see the rule in `AttendanceViewModel.toNotice`.

    /** The office could not be anchored because the fix was too coarse. */
    data class AnchorRejected(
        val reportedAccuracyMeters: Float,
        val requiredAccuracyMeters: Float,
    ) : AttendanceNotice

    /** Local storage failed; the screen is showing stale or empty data. */
    data object StorageProblem : AttendanceNotice

    /**
     * A mock-location provider is feeding the device.
     *
     * Reported, never blocked: emulators report every fix as mocked, so
     * refusing them would make the app untestable on the exact device most
     * reviewers will use. Surfacing it keeps the audit trail honest instead.
     */
    data object MockLocationActive : AttendanceNotice
}

/** Everything the user can do on this screen. */
sealed interface AttendanceIntent {
    data object ScreenStarted : AttendanceIntent

    /**
     * The screen left the foreground.
     *
     * Distinct from losing permission, and the distinction is the whole point:
     * permission says whether the app *may* read the position, visibility says
     * whether it has any reason to. Conflating them kept the GPS streaming
     * behind the home screen for as long as the Activity lived.
     */
    data object ScreenStopped : AttendanceIntent
    data object SetOfficeLocationClicked : AttendanceIntent
    data object MarkAttendanceClicked : AttendanceIntent
    data object ClearOfficeClicked : AttendanceIntent
    data object NoticeActionClicked : AttendanceIntent
    data object NoticeDismissed : AttendanceIntent

    /**
     * Result of the runtime permission dialog.
     *
     * @param canAskAgain false once the OS will no longer show the dialog,
     *   which is the only reliable way to distinguish "denied" from "blocked".
     */
    data class PermissionResult(val granted: Boolean, val canAskAgain: Boolean) : AttendanceIntent

    /** The screen reports whether permission is currently held, on every resume. */
    data class PermissionStateChanged(val granted: Boolean) : AttendanceIntent
}

/** One-shot side effects. */
sealed interface AttendanceEffect {
    data object RequestLocationPermission : AttendanceEffect
    data object OpenAppSettings : AttendanceEffect
    data object OpenLocationSettings : AttendanceEffect

    data class OfficeAnchored(val accuracyMeters: Float) : AttendanceEffect
    data class AttendanceMarked(val record: AttendanceRecord) : AttendanceEffect

    /** A transient failure worth a snackbar rather than a persistent banner. */
    data class ShowMessage(val reason: FailureReason) : AttendanceEffect
}

/** Snackbar-worthy, momentary failures. */
enum class FailureReason {
    OutsideGeofence,
    WindowClosed,
    AlreadyMarkedToday,
    OfficeNotConfigured,
    LocationTimeout,
    Unknown,
}
