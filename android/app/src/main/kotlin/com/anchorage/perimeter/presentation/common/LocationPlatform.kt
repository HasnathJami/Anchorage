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
 * The small amount of raw Android that a location screen cannot avoid.
 *
 * Four extension functions on `Context`, shared by the Attendance screen and
 * the office picker rather than copied into both.
 *
 * Duplicating [shouldShowLocationRationale] in particular would be asking for
 * trouble: it is the only way to distinguish "denied once" from "blocked
 * forever", and two copies drifting apart means one screen eventually offers
 * a system dialog that will never appear again.
 *
 * @return True when either fine or coarse location has been granted.
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
 * This is how "denied once" is told apart from "denied permanently", which
 * matters because the two have completely different remedies: one can still
 * be fixed by asking again, the other only by sending the user to Settings.
 *
 * The flag lives on `Activity`, so this walks the `ContextWrapper` chain
 * rather than assuming the composition's context is one — which it is not
 * when the screen is hosted inside a `ComposeView`.
 *
 * @return True when the system dialog would still appear if requested.
 *   Defaults to `true` when no Activity can be found, because asking and
 *   being refused is a better failure than never asking at all.
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

/**
 * Deep-links to this app's page in system Settings — the only way out of a
 * permanently denied permission.
 */
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

/**
 * Opens the system location settings, for when permission is granted but the
 * device's master location toggle is off.
 *
 * Wrapped for the same reason as [openAppSettings].
 */
internal fun Context.openLocationSettings() {
    runCatching {
        startActivity(
            Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }
}
