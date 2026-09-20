package com.anchorage.perimeter.presentation.attendance

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Turns numbers into the text the user reads: "120m", "±6 m", "09:12 AM".
 *
 * ## Why formatting lives here and nowhere else
 *
 * - **Not in the ViewModel**, so its state stays numeric and locale-free —
 *   which is what lets the ViewModel tests run without an Android `Context`.
 * - **Not in the composables**, so the rules are asserted once by unit tests
 *   rather than eyeballed in a preview.
 *
 * Every function takes an explicit `locale` (and `zone` where relevant) with
 * a sensible default, so a test can pin them and assert exact strings.
 */
internal object AttendanceFormatters {

    private const val METRES_IN_KILOMETRE = 1_000

    /**
     * Distance for the dial: "12m", "120m", "1.4 km".
     *
     * Sub-kilometre values are rounded to whole metres because a decimal on a
     * reading that jitters by several metres per second is false precision.
     */
    fun distance(meters: Double, locale: Locale = Locale.getDefault()): String = when {
        meters < METRES_IN_KILOMETRE -> "${meters.roundToInt()}m"
        else -> String.format(locale, "%.1f km", meters / METRES_IN_KILOMETRE)
    }

    /** Accuracy radius: "±6 m", shown without the sign by the caller. */
    fun accuracy(meters: Float, locale: Locale = Locale.getDefault()): String = when {
        meters >= Float.MAX_VALUE / 2 -> "unknown"
        meters < 10f -> String.format(locale, "%.1f m", meters)
        else -> "${meters.roundToInt()} m"
    }

    /** Latitude or longitude trimmed to four decimals - about 11 m of precision. */
    fun coordinate(value: Double, locale: Locale = Locale.getDefault()): String =
        String.format(locale, "%.4f", value)

    /** Wall-clock time of a record: "09:12 AM". */
    fun clockTime(
        epochMillis: Long,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String = Instant.ofEpochMilli(epochMillis)
        .atZone(zone)
        .format(DateTimeFormatter.ofPattern("hh:mm a", locale))

    /** Date of a record: "28 Aug 2026". */
    fun calendarDate(
        epochMillis: Long,
        zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault(),
    ): String = Instant.ofEpochMilli(epochMillis)
        .atZone(zone)
        .format(DateTimeFormatter.ofPattern("dd MMM yyyy", locale))
}
