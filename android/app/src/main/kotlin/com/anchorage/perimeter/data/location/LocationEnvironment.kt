package com.anchorage.perimeter.data.location

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Answers the two questions that must be asked *before* any positioning call:
 * **"am I allowed?"** and **"is the radio even on?"**
 *
 * Asking first is what turns a `SecurityException` crash — or a stream that
 * silently never emits — into a precise, actionable message on screen.
 *
 * It is a separate injectable class rather than a few inline checks so that
 * [FusedLocationTracker] can be unit-tested with a stubbed environment, with
 * no Android framework in sight.
 */
interface LocationEnvironment {

    /**
     * True when either fine **or** coarse location has been granted.
     *
     * Enough to start asking the platform for a position at all.
     */
    fun hasLocationPermission(): Boolean

    /**
     * True when fine (precise) location specifically has been granted.
     *
     * Since Android 12 the user can grant "approximate" location only, which
     * yields fixes accurate to a city block — useless against a 50 m fence.
     * The UI uses this to explain why the readings are too coarse to act on.
     */
    fun hasPreciseLocationPermission(): Boolean

    /**
     * True when the device's master location toggle is on.
     *
     * Independent of permission: a user can grant the app location access and
     * still have location switched off system-wide, in which case asking for
     * permission again would achieve nothing.
     */
    fun isLocationEnabled(): Boolean
}

/**
 * The real implementation, reading from the Android framework.
 *
 * @param context The application context, supplied by Hilt. Application
 *   rather than Activity scope, so holding it cannot leak a screen.
 */
@Singleton
class AndroidLocationEnvironment @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : LocationEnvironment {

    override fun hasLocationPermission(): Boolean =
        isGranted(Manifest.permission.ACCESS_FINE_LOCATION) ||
            isGranted(Manifest.permission.ACCESS_COARSE_LOCATION)

    override fun hasPreciseLocationPermission(): Boolean =
        isGranted(Manifest.permission.ACCESS_FINE_LOCATION)

    override fun isLocationEnabled(): Boolean {
        val manager = ContextCompat.getSystemService(context, LocationManager::class.java)
            ?: return false
        return LocationManagerCompat.isLocationEnabled(manager)
    }

    /** @param permission A `Manifest.permission` constant. */
    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
