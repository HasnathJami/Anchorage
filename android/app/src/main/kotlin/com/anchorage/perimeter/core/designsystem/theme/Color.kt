package com.anchorage.perimeter.core.designsystem.theme

import androidx.compose.ui.graphics.Color

/**
 * The Anchorage palette.
 *
 * Every value here was sampled directly from the reference design supplied
 * with the brief rather than eyeballed, which is why they are odd numbers
 * (#2B6EEA, not #2563EB). Raw colours are private to this file; screens
 * consume them exclusively through [AnchorageColors] semantic roles, so a
 * re-skin - or a future dark theme - is a single-file change.
 */
internal object Palette {
    // Brand
    val Blue600 = Color(0xFF2B6EEA)
    val Blue700 = Color(0xFF1E5AD6)
    val Blue100 = Color(0xFFDCE7FD)
    val Blue050 = Color(0xFFF0F5FE)

    // Status - out of range / danger
    val Red500 = Color(0xFFEB4141)
    val Red400 = Color(0xFFF06363)
    val Red050 = Color(0xFFFAF0F0)
    val RedRingFill = Color(0xFFFAF5F5)

    // Status - in range / success
    val Green600 = Color(0xFF15A34A)
    val Green400 = Color(0xFF34C173)
    val Green050 = Color(0xFFECF8F0)
    val GreenRingFill = Color(0xFFF4FBF6)

    // Status - caution
    val Amber600 = Color(0xFFD97706)
    val Amber050 = Color(0xFFFDF4E7)

    // Neutrals - the cool, slightly minted greys of the reference design
    val Mint050 = Color(0xFFF5FAFA)
    val Mint100 = Color(0xFFF0F5F5)
    val White = Color(0xFFFFFFFF)
    val Grey100 = Color(0xFFEDF0F0)
    val Grey200 = Color(0xFFDCE1E6)
    val Grey300 = Color(0xFFC9D2D8)
    val SlateDisabled = Color(0xFFC8D2E1)
    val Slate400 = Color(0xFFA0A8B3)
    val Slate500 = Color(0xFF7C8794)
    val Slate600 = Color(0xFF6B7580)
    val Slate800 = Color(0xFF2F3542)
    val Slate900 = Color(0xFF1F2430)

    // Map illustration
    val MapLand = Color(0xFFEDEFEA)
    val MapPark = Color(0xFFC3D7C8)
    val MapParkAlt = Color(0xFFBED7C3)
    val MapRoad = Color(0xFFFFFFFF)
    val MapRoadMinor = Color(0xFFE6E3DB)
    val MapWater = Color(0xFFB9D6E8)
}

/**
 * Semantic colour roles.
 *
 * Screens name *intent* (`distanceDangerArc`) rather than pigment (`Red400`),
 * so the reason a pixel is red survives into the code and a designer changing
 * "danger" changes it everywhere at once.
 */
data class AnchorageColors(
    val backgroundTop: Color = Palette.Mint050,
    val backgroundBottom: Color = Palette.Mint100,
    val surface: Color = Palette.White,
    val topBarSurface: Color = Palette.White,

    val primary: Color = Palette.Blue600,
    val primaryPressed: Color = Palette.Blue700,
    val onPrimary: Color = Palette.White,
    val primarySubtle: Color = Palette.Blue050,

    val textPrimary: Color = Palette.Slate800,
    val textSecondary: Color = Palette.Slate600,
    val textTertiary: Color = Palette.Slate400,
    val labelMuted: Color = Palette.Slate500,

    val outlineSubtle: Color = Palette.Grey200,
    val outlineDashed: Color = Palette.Grey300,
    val dialTrack: Color = Palette.Grey100,

    val disabledContainer: Color = Palette.SlateDisabled,
    val onDisabledContainer: Color = Palette.White,

    val dangerArc: Color = Palette.Red400,
    val dangerText: Color = Palette.Red500,
    val dangerContainer: Color = Palette.Red050,
    val dangerDialFill: Color = Palette.RedRingFill,

    val successArc: Color = Palette.Green400,
    val successText: Color = Palette.Green600,
    val successContainer: Color = Palette.Green050,
    val successDialFill: Color = Palette.GreenRingFill,

    val cautionText: Color = Palette.Amber600,
    val cautionContainer: Color = Palette.Amber050,

    val mapLand: Color = Palette.MapLand,
    val mapPark: Color = Palette.MapPark,
    val mapParkAlt: Color = Palette.MapParkAlt,
    val mapRoad: Color = Palette.MapRoad,
    val mapRoadMinor: Color = Palette.MapRoadMinor,
    val mapWater: Color = Palette.MapWater,
)
