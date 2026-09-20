package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository

/**
 * **"Clear office"** — forgets the saved anchor so a new one can be captured,
 * for example after the company moves premises.
 *
 * A one-line pass-through to the repository. It exists as a use case anyway
 * so that the presentation layer depends on *only* use cases and never
 * reaches for a repository directly — a rule the architecture test enforces.
 * The day this needs to also clear a cached geofence registration, there is
 * already a place to put that.
 */
class ClearOfficeAnchorUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
) {
    /** @return Success, or an `AppError.Storage` failure. */
    suspend operator fun invoke(): Outcome<Unit> = officeAnchorRepository.clear()
}
