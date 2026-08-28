package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.port.AttendanceRepository
import kotlinx.coroutines.flow.Flow

/** Newest-first attendance log, backing the history sheet. */
class ObserveAttendanceHistoryUseCase(
    private val attendanceRepository: AttendanceRepository,
) {
    operator fun invoke(): Flow<List<AttendanceRecord>> = attendanceRepository.observeHistory()
}
