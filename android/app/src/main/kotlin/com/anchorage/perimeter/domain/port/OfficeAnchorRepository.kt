package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.OfficeAnchor
import kotlinx.coroutines.flow.Flow

/**
 * Where the saved office lives.
 *
 * There is only ever **one** anchor — this app models a single workplace —
 * so there is no `getAll` and no id parameter. Implemented by
 * [com.anchorage.perimeter.data.repository.OfficeAnchorRepositoryImpl] on top
 * of DataStore.
 */
interface OfficeAnchorRepository {

    /**
     * The current anchor, re-emitted every time it changes.
     *
     * Because it is a [Flow], setting a new office from the picker screen
     * updates the attendance dial immediately — nothing has to be told to
     * refresh.
     *
     * @return `Outcome.Success(null)` when no office has been set yet, which
     *   is a perfectly normal state and not a failure.
     */
    fun observe(): Flow<Outcome<OfficeAnchor?>>

    /**
     * Saves [anchor], replacing whatever was there before.
     *
     * @return Success, or [com.anchorage.perimeter.core.common.error.AppError.Storage].
     */
    suspend fun save(anchor: OfficeAnchor): Outcome<Unit>

    /**
     * Forgets the saved office, returning the app to its empty state.
     *
     * @return Success, or [com.anchorage.perimeter.core.common.error.AppError.Storage].
     */
    suspend fun clear(): Outcome<Unit>
}
