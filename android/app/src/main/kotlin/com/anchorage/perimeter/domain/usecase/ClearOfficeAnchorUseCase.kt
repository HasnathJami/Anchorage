package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository

/** Forgets the saved office so a new one can be captured (e.g. after a move). */
class ClearOfficeAnchorUseCase(
    private val officeAnchorRepository: OfficeAnchorRepository,
) {
    suspend operator fun invoke(): Outcome<Unit> = officeAnchorRepository.clear()
}
