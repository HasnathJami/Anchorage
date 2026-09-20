package com.anchorage.perimeter.presentation.attendance

import androidx.compose.runtime.Immutable
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.GeofenceReading

/**
 * **The contract between the Attendance screen and its ViewModel.**
 *
 * Everything the screen can show, everything the user can do, and everything
 * that can happen once — declared in one file, so you can read this and know
 * the whole screen without opening the UI code.
 *
 * ## The pattern: MVI in three types
 *
 * ```
 *        user taps  ──►  Intent  ──►  ViewModel  ──►  use case
 *                                         │
 *        screen renders ◄──  State   ◄────┤
 *        one-shot things ◄── Effect  ◄────┘
 * ```
 *
 * - **[AttendanceUiState]** — everything that is *true right now*. The screen
 *   renders it declaratively, so replaying the same state always reproduces
 *   the same pixels.
 * - **[AttendanceIntent]** — everything the user can *do*. The screen sends
 *   these and nothing else, which is why the ViewModel's public surface is a
 *   single function.
 * - **[AttendanceEffect]** — the one-shot things that must happen *exactly
 *   once*: navigate, open the permission dialog, show a snackbar.
 *
 * ## Why effects are separate from state
 *
 * This separation is not ceremony — it fixes a specific, classic bug.
 *
 * If "show a snackbar" were a field on the state, then every recomposition
 * would see it set and show the snackbar again. Rotate the phone and it
 * reappears. Effects are consumed once and forgotten, so they cannot replay.
 *
 * ## Why the state holds numbers, not strings
 *
 * Note that [AttendanceUiState] carries *domain* values — metres, timestamps,
 * enums — rather than formatted text like `"120 m away"`. Formatting belongs
 * to the composable, which knows the locale and the available width. Keeping
 * it out of here means the ViewModel tests never need an Android `Context`.
 *
 * @property isBootstrapping True until the first status emission arrives.
 *   Drives the loading skeleton.
 * @property anchor The saved office, or `null` if none is set.
 * @property reading The current distance measurement, or `null` if there is
 *   nothing to measure yet.
 * @property todayRecord Today's check-in, if it has already happened.
 * @property proximity How the dial and status pill should read.
 * @property isWindowOpen Whether the clock is inside the check-in hours.
 * @property windowLabel Those hours, pre-formatted as "09:00 AM - 10:30 AM".
 * @property isCapturingOffice True while a "Set Office Location" is in
 *   flight. Drives that button's spinner.
 * @property isMarkingAttendance True while a check-in is in flight.
 * @property notice The persistent problem banner, or `null` when nothing is
 *   wrong.
 * @property canMarkAttendance Whether the check-in button is enabled. Copied
 *   straight from the domain — the ViewModel does not re-derive it.
 */
@Immutable
data class AttendanceUiState(
    val isBootstrapping: Boolean = true,

    val anchor: OfficeAnchor? = null,
    val reading: GeofenceReading? = null,
    val todayRecord: AttendanceRecord? = null,

    val proximity: ProximityUi = ProximityUi.Unknown,
    val isWindowOpen: Boolean = false,
    val windowLabel: String = "",

    val isCapturingOffice: Boolean = false,
    val isMarkingAttendance: Boolean = false,

    val notice: AttendanceNotice? = null,

    val canMarkAttendance: Boolean = false,

    /**
     * The fence being enforced, in metres.
     *
     * Read from the injected policy rather than from
     * `GeofencePolicy.DEFAULT_RADIUS_METERS`, so the copy on screen and the
     * decision behind it can never name different numbers. It matters for the
     * case this app stands in for: in production the radius is a property of
     * the *site* and arrives from a server, and a screen that hard-codes 50
     * would go on saying 50 over a 200 m campus.
     */
    val radiusMeters: Double = GeofencePolicy.DEFAULT_RADIUS_METERS,

    /**
     * False once the user has been asked for location permission and said no.
     *
     * Deliberately **not** a banner. The screen asks with the *system* dialog
     * on entry, so the only thing left to say afterwards is why the dial is
     * empty — and that belongs in the caption under it, next to the thing it
     * explains, rather than in a panel at the top of the screen repeating an
     * offer the user has already declined.
     */
    val hasLocationPermission: Boolean = true,
) {
    val isOfficeConfigured: Boolean get() = anchor != null

    val isAlreadyMarkedToday: Boolean get() = todayRecord != null

    /** True while either long-running action is in flight. */
    val isBusy: Boolean get() = isCapturingOffice || isMarkingAttendance
}

/**
 * How the dial and the status pill should read.
 *
 * A presentation concept, not a domain one: the domain only knows INSIDE and
 * OUTSIDE plus a confidence flag. This enum splits those into the three
 * things the *user* needs told apart.
 */
enum class ProximityUi {
    /** No office set yet, or no fix yet. The dial shows `--`. */
    Unknown,

    /** Inside the fence, on a fix worth trusting. The button is live. */
    InRange,

    /** Outside the fence. The remedy is to walk closer. */
    OutOfRange,

    /**
     * The position looks close, but its error radius is too wide to act on.
     *
     * A distinct state rather than a flavour of [OutOfRange], because the
     * user's remedy is different: wait, or step outside for a better sky
     * view — not walk closer.
     */
    LowConfidence,
}

/**
 * A persistent condition worth a banner at the top of the screen.
 *
 * ## The rule for what belongs here
 *
 * **A notice must have a remedy the user can act on.** If the condition is
 * momentary and fixes itself, a banner interrupts a screen that is still
 * telling the truth, to offer a button that does what was already happening.
 * Two cases were removed for exactly that reason — see the notes below.
 *
 * Modelled as data rather than a pre-baked string, so the same notice can
 * render as a full banner *and* as a terse content description for TalkBack,
 * without the two drifting apart.
 */
sealed interface AttendanceNotice {

    // `PermissionRequired` used to live here.
    //
    // It was a banner that said "Location permission needed" over a button
    // that opened the system dialog - an in-app dialog whose only job was to
    // summon the real one. The screen now asks directly on entry, which is
    // one fewer tap in the common case and one fewer thing to read. What
    // survives is [PermissionBlocked], and only because the system dialog
    // genuinely cannot help there: Android will not show it again, so
    // Settings is the only route and an app that does not offer it is a dead
    // end.

    /**
     * Permission was denied permanently; only the app's Settings page can fix
     * it. Remedy: a button that deep-links there.
     */
    data object PermissionBlocked : AttendanceNotice

    /**
     * Permission is granted but the device's location toggle is off.
     * Remedy: a button opening location settings.
     */
    data object LocationServicesOff : AttendanceNotice

    /**
     * Fixes are arriving but are too imprecise to gate a check-in on.
     *
     * @property accuracyMeters The reported error radius, so the banner can
     *   name it rather than being vague.
     */
    data class WeakSignal(val accuracyMeters: Float) : AttendanceNotice

    // `PositionUnavailable` used to live here, with a Retry action.
    //
    // It was removed because it had nothing to offer. The dial keeps showing
    // the last known distance through a dropout, and the stream recovers on
    // its own when the provider comes back - so the banner interrupted a
    // screen that was still telling the truth, to offer a button that did
    // what was already happening. A momentary condition with no distinct
    // remedy is not a notice; see the rule in `AttendanceViewModel.toNotice`.

    /**
     * The office could not be anchored because the fix was too coarse.
     *
     * @property reportedAccuracyMeters What the fix claimed.
     * @property requiredAccuracyMeters What the policy demanded.
     */
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

/**
 * Everything the user can do on this screen.
 *
 * The screen sends one of these and nothing else. That is what keeps the
 * ViewModel's public surface down to a single `onIntent` function, and what
 * makes the ViewModel testable by simply feeding it intents in order.
 */
sealed interface AttendanceIntent {

    /** The screen became visible. */
    data object ScreenStarted : AttendanceIntent

    /**
     * The screen left the foreground.
     *
     * Distinct from losing permission, and the distinction is the whole
     * point: permission says whether the app *may* read the position,
     * visibility says whether it has any reason to. Conflating them kept the
     * GPS streaming behind the home screen for as long as the Activity lived.
     */
    data object ScreenStopped : AttendanceIntent

    /** "Set Office Location" — capture the current position as the anchor. */
    data object SetOfficeLocationClicked : AttendanceIntent

    /** The main button. */
    data object MarkAttendanceClicked : AttendanceIntent

    /** Forget the saved office. */
    data object ClearOfficeClicked : AttendanceIntent

    /** The button inside the notice banner, whatever it currently offers. */
    data object NoticeActionClicked : AttendanceIntent

    /** The banner's close button. */
    data object NoticeDismissed : AttendanceIntent

    /**
     * The user answered the runtime permission dialog.
     *
     * @param granted Whether permission was given.
     * @param canAskAgain `false` once the OS will no longer show the dialog.
     *   This is the only reliable way to tell "denied" from "blocked", and
     *   they need different remedies — hence two separate error cases.
     */
    data class PermissionResult(val granted: Boolean, val canAskAgain: Boolean) : AttendanceIntent

    /**
     * The screen reports whether permission is currently held. Sent on every
     * resume, because the user may have changed it in Settings while away.
     */
    data class PermissionStateChanged(val granted: Boolean) : AttendanceIntent
}

/**
 * Things that must happen exactly **once** — never re-run on recomposition.
 *
 * See the note on replay in the [AttendanceUiState] docs for why these are
 * not fields on the state.
 */
sealed interface AttendanceEffect {

    /** Ask the OS to show the runtime permission dialog. */
    data object RequestLocationPermission : AttendanceEffect

    /** Deep-link to this app's page in system Settings. */
    data object OpenAppSettings : AttendanceEffect

    /** Open the system location settings screen. */
    data object OpenLocationSettings : AttendanceEffect

    /**
     * The office was saved successfully.
     *
     * @property accuracyMeters Reported so the confirmation can say how good
     *   the anchor is.
     */
    data class OfficeAnchored(val accuracyMeters: Float) : AttendanceEffect

    /** A check-in was written. Carries the record for the confirmation. */
    data class AttendanceMarked(val record: AttendanceRecord) : AttendanceEffect

    /** A transient failure worth a snackbar rather than a persistent banner. */
    data class ShowMessage(val reason: FailureReason) : AttendanceEffect
}

/**
 * Momentary failures worth a snackbar.
 *
 * These are conditions the user caused by tapping at the wrong moment, and
 * they resolve themselves. Compare [AttendanceNotice], which is for standing
 * conditions that need a remedy.
 */
enum class FailureReason {
    /** Tapped while outside the fence. */
    OutsideGeofence,

    /** Tapped outside the permitted hours. */
    WindowClosed,

    /** Tapped when today was already recorded. */
    AlreadyMarkedToday,

    /** Tapped before setting an office. */
    OfficeNotConfigured,

    /** No fix arrived in time to decide. */
    LocationTimeout,

    /** The catch-all, so a new failure always renders *something*. */
    Unknown,
}
