package com.anchorage.perimeter

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * The application entry point, and the root of the Hilt object graph.
 *
 * `@HiltAndroidApp` is what generates the dependency-injection container for
 * the whole app. Every `@AndroidEntryPoint` (there is one: [MainActivity])
 * and every `@HiltViewModel` gets its dependencies from here.
 *
 * ## Why it is empty
 *
 * Deliberately. Anything done in `Application.onCreate` runs on the critical
 * path of **every** cold start, so it directly costs launch time. Everything
 * Anchorage needs — DataStore, Room, the fused location client — is created
 * lazily by Hilt the first time it is actually injected, which for most
 * launches is after the first frame is already on screen.
 */
@HiltAndroidApp
class AnchorageApplication : Application()
