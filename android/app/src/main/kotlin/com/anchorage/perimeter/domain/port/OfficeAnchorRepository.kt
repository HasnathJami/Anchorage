package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.OfficeAnchor
import kotlinx.coroutines.flow.Flow

/** Persistence port for the single saved office anchor. */
interface OfficeAnchorRepository {

    /** Emits the current anchor, or `null` when none has been captured yet. */
    fun observe(): Flow<Outcome<OfficeAnchor?>>

    suspend fun save(anchor: OfficeAnchor): Outcome<Unit>

    suspend fun clear(): Outcome<Unit>
}
