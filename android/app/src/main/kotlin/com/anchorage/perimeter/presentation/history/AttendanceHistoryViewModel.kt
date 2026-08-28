package com.anchorage.perimeter.presentation.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.usecase.ObserveAttendanceHistoryUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

/**
 * Read-only projection of the attendance log.
 *
 * `WhileSubscribed(5_000)` is safe here - unlike the location stream - because
 * the underlying source is a Room query, so keeping it warm across a rotation
 * costs nothing but avoids a visible re-query flicker.
 */
@HiltViewModel
class AttendanceHistoryViewModel @Inject constructor(
    observeAttendanceHistory: ObserveAttendanceHistoryUseCase,
) : ViewModel() {

    val records: StateFlow<List<AttendanceRecord>> = observeAttendanceHistory()
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5_000),
            initialValue = emptyList(),
        )
}
