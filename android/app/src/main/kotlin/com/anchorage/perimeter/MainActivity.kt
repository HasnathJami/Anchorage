package com.anchorage.perimeter

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.presentation.navigation.AnchorageNavHost
import dagger.hilt.android.AndroidEntryPoint

/**
 * The one and only Activity.
 *
 * Anchorage is a single-Activity, Compose-navigation app: no fragments, no
 * per-screen Activity. So the only platform lifecycle that matters is this
 * one.
 *
 * That simplification is what keeps the location stream's lifetime easy to
 * reason about. The GPS runs only while the attendance screen is both
 * permitted and visible, and "visible" is bounded by this Activity's
 * lifecycle, through the ViewModel, through the navigation back stack entry.
 * With three Activities and a fragment layer, that chain would be much harder
 * to hold in your head — and the battery bug much easier to write.
 *
 * ## The whole startup sequence
 *
 * ```
 * AnchorageApplication  (builds the Hilt graph)
 *   └─ MainActivity     (this file)
 *        └─ AnchorageTheme      (colours, type, shapes)
 *             └─ AnchorageNavHost  (routes between the three screens)
 * ```
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the status and navigation bars. Called before
        // super.onCreate so the window is configured before the first frame.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        setContent {
            AnchorageTheme {
                // `finishAffinity` rather than `finish`: the user asked to
                // leave the app, not to pop one screen off it. With a single
                // Activity the two happen to coincide today, and naming the
                // intent keeps that true if a second one is ever added.
                AnchorageNavHost(onExitApp = ::finishAffinity)
            }
        }
    }
}
