package com.anchorage.perimeter

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Application entry point and the root of the Hilt object graph.
 *
 * It is intentionally empty beyond the annotation: work done in
 * `Application.onCreate` runs on the critical path of every cold start, and
 * everything Anchorage needs (DataStore, Room, the fused client) is created
 * lazily by Hilt the first time it is actually injected.
 */
@HiltAndroidApp
class AnchorageApplication : Application()
