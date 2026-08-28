package com.anchorage.perimeter.presentation.common

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * The small amount of Android that a location screen cannot avoid.
 *
 * Shared by Attendance and the office picker rather than copied into both.
 * Duplicating [shouldShowLocationRationale] in particular would be asking for
 * trouble: it is the only way to distinguish "denied once" from "blocked
 * forever", and two copies drifting apart means one screen eventually offers
 * a system dialog that will never appear again.
 */
internal fun Context.hasLocationPermission(): Boolean =
    ContextCompat.checkSelfPermission(
        this,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

/**
 * True while Android is still willing to show the permission dialog.
 *
 * The flag lives on Activity, so this walks the ContextWrapper chain rather
 * than assuming the composition's context is one - which it is not when the
 * screen is hosted inside a `ComposeView`.
 */
internal fun Context.shouldShowLocationRationale(): Boolean {
    val activity = generateSequence(this) { (it as? ContextWrapper)?.baseContext }
        .filterIsInstance<Activity>()
        .firstOrNull() ?: return true

    return ActivityCompat.shouldShowRequestPermissionRationale(
        activity,
        Manifest.permission.ACCESS_FINE_LOCATION,
    )
}

internal fun Context.openAppSettings() {
    // Wrapped because a stripped-down device (or a work profile) can have no
    // activity for this intent, and an ActivityNotFoundException here would
    // crash the app while trying to help the user fix a permission.
    runCatching {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }
}

internal fun Context.openLocationSettings() {
    runCatching {
        startActivity(
            Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }
}
