package com.anchorage.perimeter.data.location

import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.common.truth.Truth.assertThat
import io.mockk.mockk
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test

/**
 * Covers the preflight gate - the part of the tracker that must never reach
 * Play Services. The happy path needs real hardware and lives in the
 * instrumentation suite; what matters here is that a missing permission or a
 * disabled radio produces a precise, non-throwing failure.
 */
class FusedLocationTrackerTest {

    private class StubEnvironment(
        var permission: Boolean = true,
        var enabled: Boolean = true,
        var precise: Boolean = true,
    ) : LocationEnvironment {
        override fun hasLocationPermission() = permission
        override fun hasPreciseLocationPermission() = precise
        override fun isLocationEnabled() = enabled
    }

    private val dispatcher: CoroutineDispatcher = StandardTestDispatcher()
    private val dispatchers = object : DispatcherProvider {
        override val main = dispatcher
        override val io = dispatcher
        override val default = dispatcher
    }

    private val client: FusedLocationProviderClient = mockk(relaxed = true)

    private fun tracker(environment: LocationEnvironment) =
        FusedLocationTracker(client, environment, dispatchers)

    @Test
    fun `stream reports permission denied without contacting play services`() = runTest {
        val outcome = tracker(StubEnvironment(permission = false)).stream().first()

        assertThat((outcome as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.PermissionDenied::class.java)
    }

    @Test
    fun `stream reports services disabled when the radio is off`() = runTest {
        val outcome = tracker(StubEnvironment(enabled = false)).stream().first()

        assertThat((outcome as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.ServicesDisabled::class.java)
    }

    @Test
    fun `currentFix reports permission denied without contacting play services`() = runTest {
        val outcome = tracker(StubEnvironment(permission = false)).currentFix()

        assertThat((outcome as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.PermissionDenied::class.java)
    }

    @Test
    fun `currentFix reports services disabled when the radio is off`() = runTest {
        val outcome = tracker(StubEnvironment(enabled = false)).currentFix()

        assertThat((outcome as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.ServicesDisabled::class.java)
    }

    @Test
    fun `permission is checked before the location toggle`() = runTest {
        // Both broken: the user must be told about the permission first, since
        // fixing the toggle alone would not help.
        val outcome = tracker(StubEnvironment(permission = false, enabled = false)).currentFix()

        assertThat((outcome as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.PermissionDenied::class.java)
    }
}
