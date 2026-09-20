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
 * The history screen's state holder — a read-only projection of the log.
 *
 * There are no intents and no effects here, because there is nothing to do on
 * this screen but look at it. Compare [AttendanceViewModel], which needs the
 * full MVI machinery.
 *
 * ## Why `WhileSubscribed(5_000)` is safe here
 *
 * It keeps the underlying flow alive for five seconds after the last
 * collector goes away, so a screen rotation does not tear it down and rebuild
 * it — which would show a visible re-query flicker.
 *
 * That would be the **wrong** choice for the location stream, where staying
 * warm means keeping the GPS on. Here the source is a Room query, so staying
 * warm costs nothing at all. Same operator, opposite verdict — the cost of
 * the upstream is what decides it.
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
