package com.anchorage.perimeter.data.repository

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.data.local.datastore.OfficeAnchorLocalSource
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Thin adapter from the domain port to the DataStore source.
 *
 * It is deliberately trivial. All the interesting behaviour - corruption
 * handling, partial-write tolerance - lives in the source, and all the rules
 * live in the use cases. A repository that grew logic of its own would become
 * a third place to look for the truth.
 */
@Singleton
class OfficeAnchorRepositoryImpl @Inject constructor(
    private val localSource: OfficeAnchorLocalSource,
) : OfficeAnchorRepository {

    override fun observe(): Flow<Outcome<OfficeAnchor?>> = localSource.observe()

    override suspend fun save(anchor: OfficeAnchor): Outcome<Unit> = localSource.save(anchor)

    override suspend fun clear(): Outcome<Unit> = localSource.clear()
}
