package com.anchorage.perimeter

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.presentation.navigation.AnchorageNavHost
import dagger.hilt.android.AndroidEntryPoint

/**
 * The single Activity.
 *
 * Anchorage is a one-Activity, Compose-navigation app: there is no fragment
 * layer and no per-screen Activity, so the only platform lifecycle that
 * matters is this one. That keeps the location stream's lifetime easy to
 * reason about - it is bounded by the ViewModel, which is bounded by the
 * navigation back stack entry.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
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
