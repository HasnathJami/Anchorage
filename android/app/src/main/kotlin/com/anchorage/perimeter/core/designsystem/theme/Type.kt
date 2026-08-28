package com.anchorage.perimeter.core.designsystem.theme

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp

/**
 * The Anchorage type scale.
 *
 * Deliberately small and named after its job rather than after a generic
 * `titleMedium` rung: the reference design uses exactly seven text treatments
 * and naming them for their role stops a developer from reaching for a
 * near-miss and slowly eroding the design.
 *
 * Letter spacing on the "eyebrow" styles is not decoration - the reference
 * relies on wide tracking to make 10-11sp uppercase labels legible.
 */
data class AnchorageTypography(
    /** Top bar title, e.g. "Attendance". */
    val screenTitle: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
        letterSpacing = 0.1.sp,
    ),

    /** Section eyebrow, e.g. "STEP 1: OFFICE CONTEXT". */
    val sectionEyebrow: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 1.3.sp,
    ),

    /** Explanatory copy inside cards. */
    val body: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 19.sp,
        letterSpacing = 0.05.sp,
    ),

    /** Centred helper copy under the dial. */
    val caption: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 17.sp,
        textAlign = TextAlign.Center,
    ),

    /** The distance numeral at the centre of the dial. */
    val dialValue: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 34.sp,
        lineHeight = 38.sp,
        letterSpacing = (-0.5).sp,
    ),

    /** Micro uppercase labels: "AWAY", "OUT OF RANGE", "AVAILABLE 09:00 ...". */
    val microLabel: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 10.sp,
        lineHeight = 13.sp,
        letterSpacing = 1.6.sp,
    ),

    /** Button labels. */
    val button: TextStyle = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.2.sp,
    ),

    /** The lat/lon read-out; monospaced so digits do not jitter as they update. */
    val coordinate: TextStyle = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.2.sp,
    ),
)
