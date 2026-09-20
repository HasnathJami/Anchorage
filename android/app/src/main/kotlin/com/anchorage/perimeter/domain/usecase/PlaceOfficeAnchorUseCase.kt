package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.core.common.outcome.map
import com.anchorage.perimeter.domain.model.AnchorSource
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider

/**
 * **"Confirm this spot"** — the user dropped a pin on the map picker and
 * wants that to become the office.
 *
 * ## Why this is not just [CaptureOfficeAnchorUseCase] with a flag
 *
 * The two differ in the one rule that actually matters:
 *
 * - [CaptureOfficeAnchorUseCase] takes a **live fix** and refuses it if the
 *   error radius is wider than the policy allows, because a sloppy fix would
 *   poison every future comparison.
 * - This one has **no fix** to be sloppy about. The user looked at a map and
 *   pointed at a building. There is no measurement to gate, so gating would
 *   be theatre.
 *
 * What the two share is the consequence: whatever lands here becomes the
 * point every future check-in is measured against. So it is recorded with its
 * provenance ([AnchorSource.ManualPlacement]) rather than being passed off as
 * a fix that never happened.
 *
 * @param officeAnchorRepository Where the anchor is saved.
 * @param timeProvider Supplies the capture timestamp. Injected so tests are
 *   deterministic.
 */
class PlaceOfficeAnchorUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val timeProvider: TimeProvider,
) {

    /**
     * @param point Where the user placed the pin.
     * @param label What to call this place on the office card.
     * @return The saved anchor, or an
     *   [com.anchorage.perimeter.core.common.error.AppError.Storage] failure.
     */
    suspend operator fun invoke(
        point: GeoPoint,
        label: String = OfficeAnchor.DEFAULT_LABEL,
    ): Outcome<OfficeAnchor> {
        val anchor = OfficeAnchor(
            point = point,
            // Not a measurement. `source` below is what the UI reads to
            // decide whether an accuracy may be shown at all; zero here means
            // "unmeasured", never "perfect".
            accuracyMeters = 0f,
            capturedAtEpochMillis = timeProvider.nowEpochMillis(),
            label = label,
            source = AnchorSource.ManualPlacement,
        )
        return officeAnchorRepository.save(anchor).map { anchor }
    }
}
