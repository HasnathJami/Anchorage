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
 * "am I allowed?" and "is the radio even on?".
 *
 * Asking first is what turns a `SecurityException` crash or a silent
 * never-emitting stream into a precise, actionable message on screen. It is a
 * separate injectable class rather than inline checks so the tracker can be
 * unit-tested with a stubbed environment.
 */
interface LocationEnvironment {

    /** True when either fine or coarse location has been granted. */
    fun hasLocationPermission(): Boolean

    /** True when fine (precise) location specifically has been granted. */
    fun hasPreciseLocationPermission(): Boolean

    /** True when the device's master location toggle is on. */
    fun isLocationEnabled(): Boolean
}

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

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
