package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.core.common.outcome.map
import com.anchorage.perimeter.domain.model.AnchorSource
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider

/**
 * "Confirm this spot": freeze a hand-placed pin as the office anchor.
 *
 * The sibling of [CaptureOfficeAnchorUseCase], and deliberately *not* the same
 * use case with a flag. The two differ in the one rule that matters:
 *
 *  * [CaptureOfficeAnchorUseCase] takes a live fix and **refuses** it if the
 *    error radius is wider than the policy allows, because a sloppy fix would
 *    poison every future comparison.
 *  * This one has no fix to be sloppy about. The user looked at a map and
 *    pointed. There is no measurement to gate, so gating would be theatre.
 *
 * What the two share is the consequence: whatever lands here is the point
 * every future check-in is measured against, so it is recorded with its
 * provenance ([AnchorSource.ManualPlacement]) rather than being passed off as
 * a fix that never happened.
 */
class PlaceOfficeAnchorUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val timeProvider: TimeProvider,
) {

    suspend operator fun invoke(
        point: GeoPoint,
        label: String = OfficeAnchor.DEFAULT_LABEL,
    ): Outcome<OfficeAnchor> {
        val anchor = OfficeAnchor(
            point = point,
            // Not a measurement. `source` is what the UI reads to decide
            // whether an accuracy may be shown at all; zero here means
            // "unmeasured", never "perfect".
            accuracyMeters = 0f,
            capturedAtEpochMillis = timeProvider.nowEpochMillis(),
            label = label,
            source = AnchorSource.ManualPlacement,
        )
        return officeAnchorRepository.save(anchor).map { anchor }
    }
}
