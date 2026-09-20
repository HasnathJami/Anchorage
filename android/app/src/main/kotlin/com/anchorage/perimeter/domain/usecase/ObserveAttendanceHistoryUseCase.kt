package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.port.AttendanceRepository
import kotlinx.coroutines.flow.Flow

/**
 * The newest-first attendance log that backs the history screen.
 *
 * Like [ClearOfficeAnchorUseCase], a deliberate pass-through: it keeps the
 * presentation layer's dependencies uniform (ViewModels talk to use cases,
 * never to repositories) at the cost of one small file.
 */
class ObserveAttendanceHistoryUseCase(
    private val attendanceRepository: AttendanceRepository,
) {
    /**
     * @return A [Flow] that re-emits the whole list whenever a record is
     *   added, so the history screen updates by itself.
     */
    operator fun invoke(): Flow<List<AttendanceRecord>> = attendanceRepository.observeHistory()
}
