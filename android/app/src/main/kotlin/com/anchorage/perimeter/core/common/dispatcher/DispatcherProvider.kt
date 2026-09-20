package com.anchorage.perimeter.core.common.dispatcher

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * "Which thread should this run on?", as something you can inject.
 *
 * ## Why not just call `Dispatchers.IO` directly?
 *
 * Because a repository that hard-codes `Dispatchers.IO` cannot be tested
 * without `Dispatchers.setMain` gymnastics and hidden thread hops — the test
 * finishes before the work does, and you end up sprinkling delays to make it
 * pass.
 *
 * Every Anchorage component that needs to switch threads takes this port
 * instead. Tests hand it a single `StandardTestDispatcher`, so all the work
 * lands on one controllable thread and execution becomes fully deterministic.
 *
 * Same principle as [com.anchorage.perimeter.domain.port.TimeProvider] and
 * [com.anchorage.perimeter.domain.port.IdGenerator]: anything
 * non-deterministic is a dependency, never a direct call.
 */
interface DispatcherProvider {
    /** The UI thread. Anything touching Compose state belongs here. */
    val main: CoroutineDispatcher

    /** For blocking work: disk, database, network. */
    val io: CoroutineDispatcher

    /** For CPU-bound work: parsing, sorting, image decoding. */
    val default: CoroutineDispatcher
}

/** The real implementation, backed by Kotlin's [Dispatchers]. */
object StandardDispatcherProvider : DispatcherProvider {
    override val main: CoroutineDispatcher get() = Dispatchers.Main
    override val io: CoroutineDispatcher get() = Dispatchers.IO
    override val default: CoroutineDispatcher get() = Dispatchers.Default
}
