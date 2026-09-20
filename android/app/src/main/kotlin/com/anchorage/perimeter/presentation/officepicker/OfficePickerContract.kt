package com.anchorage.perimeter.presentation.officepicker

import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate

/**
 * **The office picker's contract** — the map screen where the user drops a
 * pin to set the office by hand.
 *
 * Same MVI shape as the attendance screen: a state, a set of intents, a set
 * of one-shot effects. See
 * [com.anchorage.perimeter.presentation.attendance.AttendanceUiState] for the
 * pattern explained in full.
 *
 * ## The pin does not move — the map moves under it
 *
 * Every slippy-map picker worth using works this way, because a pin dragged
 * by a fingertip is a pin *hidden* by a fingertip, and the one pixel the user
 * most needs to see is the one they are covering.
 *
 * So [centre] is both "where the camera is" **and** "where the office would
 * be", and the marker is simply drawn at the exact centre of the viewport.
 *
 * @property centre The coordinate under the marker. What would be saved.
 * @property zoom Current zoom level, between [MIN_ZOOM] and [MAX_ZOOM].
 * @property userLocation Where the user actually is, if known. Drawn as a
 *   separate blue dot — it is *not* the same thing as [centre].
 * @property userAccuracyMeters The error radius of [userLocation].
 * @property isLocating True while a "find me" request is in flight.
 * @property isSaving True while the confirm is being written.
 * @property hasExistingAnchor Whether an office was already set, which
 *   decides whether the map opens on it or on the user.
 * @property hasCentredOnSomething False until the map has been moved to a
 *   real place. The only gate on saving — see [canConfirm].
 * @property tiles The downloaded map images, keyed by their coordinate.
 * @property isMapImageryDegraded True when tiles could not be fetched. The
 *   map falls back to a plain grid and everything still works.
 * @property notice A blocking problem, shown as a dialog.
 */
data class OfficePickerUiState(
    val centre: GeoPoint = WORLD_CENTRE,
    val zoom: Int = WORLD_ZOOM,
    val userLocation: GeoPoint? = null,
    val userAccuracyMeters: Float? = null,
    val isLocating: Boolean = false,
    val isSaving: Boolean = false,
    val hasExistingAnchor: Boolean = false,
    val hasCentredOnSomething: Boolean = false,
    val tiles: Map<TileCoordinate, ByteArray> = emptyMap(),
    val isMapImageryDegraded: Boolean = false,
    val notice: PickerNotice? = null,
) {

    /**
     * The only gate on saving — and note that it is **not** a geofence one.
     *
     * The picker never refuses a location for being too far from the user:
     * people set up an office from home, from the car park, from the wrong
     * floor. It refuses exactly one thing — saving [WORLD_CENTRE], the
     * placeholder nobody chose.
     *
     * Whether the user is actually *at* the office is a question for
     * check-in, asked against the saved anchor.
     */
    val canConfirm: Boolean get() = !isSaving && hasCentredOnSomething

    companion object {
        /**
         * Where the map sits before anything is known.
         *
         * Deliberately the whole world rather than a hard-coded city:
         * guessing a location the user is not in is worse than showing them
         * they need to press "find me", and any city chosen here would be
         * wrong for almost everyone.
         */
        val WORLD_CENTRE = GeoPoint(latitude = 20.0, longitude = 0.0)

        /** Zoomed all the way out. Pairs with [WORLD_CENTRE]. */
        const val WORLD_ZOOM = 2

        /** Close enough to tell one building from its neighbour. */
        const val PLACE_ZOOM = 17

        const val MIN_ZOOM = 2
        const val MAX_ZOOM = 19
    }
}

/** Everything the user (or the canvas) can do on the picker. */
sealed interface OfficePickerIntent {

    /** The screen opened. Triggers reading the existing anchor. */
    data object ScreenStarted : OfficePickerIntent

    /** Permission state, re-reported on every resume. */
    data class PermissionStateChanged(val granted: Boolean) : OfficePickerIntent

    /**
     * The user answered the permission dialog.
     *
     * @param canAskAgain `false` once Android will no longer show it, which
     *   is the only way to tell "denied" from "blocked".
     */
    data class PermissionResult(val granted: Boolean, val canAskAgain: Boolean) : OfficePickerIntent

    /**
     * The map was panned.
     *
     * @param point The new coordinate under the marker — and therefore the
     *   new candidate office location.
     */
    data class CentreMoved(val point: GeoPoint) : OfficePickerIntent

    /** The user pinched or tapped the zoom buttons. */
    data class ZoomChanged(val zoom: Int) : OfficePickerIntent

    /**
     * The canvas worked out which tile images it needs for the current
     * viewport and is asking for them.
     *
     * Sent by the view rather than computed in the ViewModel, because only
     * the view knows its own pixel size.
     */
    data class TilesRequested(val tiles: List<TileCoordinate>) : OfficePickerIntent

    /** "Find me" — centre the map on the user's real position. */
    data object FindMeClicked : OfficePickerIntent

    /** Save the coordinate under the marker as the office. */
    data object ConfirmClicked : OfficePickerIntent

    /** The button in the notice dialog, whatever it currently offers. */
    data object NoticeActionClicked : OfficePickerIntent

    /** The notice dialog was dismissed. */
    data object NoticeDismissed : OfficePickerIntent
}

/** Things that must happen exactly once. */
sealed interface OfficePickerEffect {
    data object RequestLocationPermission : OfficePickerEffect
    data object OpenAppSettings : OfficePickerEffect
    data object OpenLocationSettings : OfficePickerEffect

    /**
     * Saved successfully; the screen should pop back to Attendance.
     *
     * No result is passed back through navigation — Attendance observes the
     * anchor repository, so the save reaches it through the same flow that
     * feeds the dial. One source of truth, and no `savedStateHandle`
     * round-trip to keep in sync with it.
     */
    data class Saved(val point: GeoPoint) : OfficePickerEffect

    /** A momentary message. */
    data class ShowMessage(val reason: PickerMessage) : OfficePickerEffect
}

/**
 * A blocking problem, rendered as a dialog with exactly one remedy.
 *
 * Same rule as the Attendance screen's banners: two cases that would show the
 * same words and the same button are one case.
 *
 * [PermissionRequired] and [PermissionBlocked] are separate because one
 * re-opens the system dialog and the other opens Settings.
 * [MapImageryUnavailable] is separate from every location case because
 * reconnecting fixes it and stepping outside does not.
 */
sealed interface PickerNotice {
    /** Not asked yet, or declined once. The dialog can still be shown. */
    data object PermissionRequired : PickerNotice

    /** Declined permanently. Only Settings can fix it. */
    data object PermissionBlocked : PickerNotice

    /** The device's location toggle is off. */
    data object ServicesDisabled : PickerNotice

    /**
     * No usable fix. Unlike on the attendance screen, this *does* get a
     * notice here — the picker needs a position to centre on, so Retry
     * actually does something.
     */
    data object PositionUnavailable : PickerNotice

    /** "Find me" ran out of time. */
    data object LocationTimeout : PickerNotice

    /** Tiles will not load. Cosmetic: the picker still works on a grid. */
    data object MapImageryUnavailable : PickerNotice

    /** Writing the anchor failed. */
    data object SaveFailed : PickerNotice
}

/** One-shot snackbar reasons. */
enum class PickerMessage {
    /** The office was written. */
    Saved,

    /** Confirm was tapped on the untouched world view. */
    NothingToSave,

    /** The catch-all, so a new failure always renders something. */
    Unknown,
}
