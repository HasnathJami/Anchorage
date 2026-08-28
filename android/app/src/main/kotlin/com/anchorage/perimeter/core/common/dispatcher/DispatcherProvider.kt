package com.anchorage.perimeter.core.common.dispatcher

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * Injectable seam over [Dispatchers].
 *
 * Hard-coding `Dispatchers.IO` inside a repository makes that repository
 * untestable without `Dispatchers.setMain` gymnastics and hidden thread hops.
 * Every Anchorage component that needs to switch threads takes this port, and
 * tests hand it a single `StandardTestDispatcher` so execution is fully
 * deterministic.
 */
interface DispatcherProvider {
    val main: CoroutineDispatcher
    val io: CoroutineDispatcher
    val default: CoroutineDispatcher
}

/** Production implementation backed by the real [Dispatchers]. */
object StandardDispatcherProvider : DispatcherProvider {
    override val main: CoroutineDispatcher get() = Dispatchers.Main
    override val io: CoroutineDispatcher get() = Dispatchers.IO
    override val default: CoroutineDispatcher get() = Dispatchers.Default
}
