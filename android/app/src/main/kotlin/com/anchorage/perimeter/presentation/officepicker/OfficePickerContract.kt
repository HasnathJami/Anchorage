package com.anchorage.perimeter.presentation.officepicker

import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate

/**
 * The office picker's MVI contract.
 *
 * The pin does not move; the map moves under it. Every slippy-map picker worth
 * using works this way, because a pin dragged by a fingertip is a pin hidden
 * by a fingertip - and the one pixel the user most needs to see is the one
 * they are covering. So [centre] is both "where the camera is" and "where the
 * office would be", and the marker is dropped at the exact centre of the
 * viewport.
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
     * The only gate on saving, and it is not a geofence one.
     *
     * The picker never refuses a location for being too far from the user:
     * people set up an office from home, from the car park, from the wrong
     * floor. It refuses exactly one thing - saving [WORLD_CENTRE], the
     * placeholder nobody chose. Whether the user is actually *at* the office
     * is a question for check-in, asked against the saved anchor.
     */
    val canConfirm: Boolean get() = !isSaving && hasCentredOnSomething

    companion object {
        /**
         * Where the map sits before anything is known.
         *
         * Deliberately the whole world rather than a hard-coded city: guessing
         * a location the user is not in is worse than showing them they need
         * to press "find me", and any city chosen here would be wrong for
         * almost everyone.
         */
        val WORLD_CENTRE = GeoPoint(latitude = 20.0, longitude = 0.0)
        const val WORLD_ZOOM = 2

        /** Close enough to tell one building from its neighbour. */
        const val PLACE_ZOOM = 17
        const val MIN_ZOOM = 2
        const val MAX_ZOOM = 19
    }
}

sealed interface OfficePickerIntent {
    data object ScreenStarted : OfficePickerIntent
    data class PermissionStateChanged(val granted: Boolean) : OfficePickerIntent
    data class PermissionResult(val granted: Boolean, val canAskAgain: Boolean) : OfficePickerIntent

    /** The map was panned; [point] is the new coordinate under the marker. */
    data class CentreMoved(val point: GeoPoint) : OfficePickerIntent
    data class ZoomChanged(val zoom: Int) : OfficePickerIntent

    /** The canvas resolved which tiles it needs for the current viewport. */
    data class TilesRequested(val tiles: List<TileCoordinate>) : OfficePickerIntent

    data object FindMeClicked : OfficePickerIntent
    data object ConfirmClicked : OfficePickerIntent
    data object NoticeActionClicked : OfficePickerIntent
    data object NoticeDismissed : OfficePickerIntent
}

sealed interface OfficePickerEffect {
    data object RequestLocationPermission : OfficePickerEffect
    data object OpenAppSettings : OfficePickerEffect
    data object OpenLocationSettings : OfficePickerEffect

    /** Saved successfully; the screen should pop back to Attendance. */
    data class Saved(val point: GeoPoint) : OfficePickerEffect
    data class ShowMessage(val reason: PickerMessage) : OfficePickerEffect
}

/**
 * A blocking problem, rendered as a dialog with exactly one remedy.
 *
 * Same rule as the Attendance screen's banners: two cases that would show the
 * same words and the same button are one case. [PermissionRequired] and
 * [PermissionBlocked] are separate because one re-opens the system dialog and
 * the other opens Settings; [MapImageryUnavailable] is separate from every
 * location case because reconnecting fixes it and stepping outside does not.
 */
sealed interface PickerNotice {
    data object PermissionRequired : PickerNotice
    data object PermissionBlocked : PickerNotice
    data object ServicesDisabled : PickerNotice
    data object PositionUnavailable : PickerNotice
    data object LocationTimeout : PickerNotice
    data object MapImageryUnavailable : PickerNotice
    data object SaveFailed : PickerNotice
}

/** One-shot snackbar reasons. */
enum class PickerMessage { Saved, NothingToSave, Unknown }
