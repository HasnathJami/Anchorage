import 'package:flutter/material.dart';

/// The Harbor palette.
///
/// Sampled from the reference design supplied with the brief rather than
/// eyeballed - hence the specific values (`#235FEB`, not `#2563EB`). The raw
/// swatches are private; widgets consume the semantic roles below so a
/// re-skin is a one-file change.
abstract final class _Swatch {
  // Surfaces - a near-black navy that lets a camera preview and a photo
  // thumbnail both sit on it without a colour cast.
  static const Color abyss = Color(0xFF000514);
  static const Color deep = Color(0xFF050A19);
  static const Color panel = Color(0xFF0A1428);
  static const Color card = Color(0xFF0F1428);
  static const Color cardRaised = Color(0xFF101A30);
  static const Color hairline = Color(0xFF0F2332);

  // Brand
  static const Color blue = Color(0xFF235FEB);
  static const Color blueBright = Color(0xFF3782F5);
  static const Color bluePressed = Color(0xFF1B4FC8);
  static const Color blueGhost = Color(0x1F3782F5);

  // Status
  static const Color green = Color(0xFF1EA97C);
  static const Color greenGhost = Color(0x1F1EA97C);
  static const Color amber = Color(0xFFE0A33B);
  static const Color amberGhost = Color(0x1FE0A33B);
  static const Color red = Color(0xFFF26F6F);
  static const Color redGhost = Color(0x1FF26F6F);

  // Text
  static const Color textPrimary = Color(0xFFF2F4F8);
  static const Color textSecondary = Color(0xFF919196);
  static const Color textTertiary = Color(0xFF5A6469);

  // Camera chrome - translucent so the preview reads through it.
  static const Color scrim = Color(0x66000000);
  static const Color scrimStrong = Color(0x99000000);
  static const Color chrome = Color(0xB2FFFFFF);
}

/// Semantic colour roles. Widgets name intent, never pigment.
@immutable
class HarborColors extends ThemeExtension<HarborColors> {
  const HarborColors({
    this.background = _Swatch.abyss,
    this.backgroundElevated = _Swatch.deep,
    this.panel = _Swatch.panel,
    this.card = _Swatch.card,
    this.cardActive = _Swatch.cardRaised,
    this.hairline = _Swatch.hairline,
    this.primary = _Swatch.blue,
    this.primaryBright = _Swatch.blueBright,
    this.primaryPressed = _Swatch.bluePressed,
    this.primaryGhost = _Swatch.blueGhost,
    this.success = _Swatch.green,
    this.successGhost = _Swatch.greenGhost,
    this.caution = _Swatch.amber,
    this.cautionGhost = _Swatch.amberGhost,
    this.danger = _Swatch.red,
    this.dangerGhost = _Swatch.redGhost,
    this.textPrimary = _Swatch.textPrimary,
    this.textSecondary = _Swatch.textSecondary,
    this.textTertiary = _Swatch.textTertiary,
    this.cameraScrim = _Swatch.scrim,
    this.cameraScrimStrong = _Swatch.scrimStrong,
    this.cameraChrome = _Swatch.chrome,
  });

  final Color background;
  final Color backgroundElevated;
  final Color panel;
  final Color card;
  final Color cardActive;
  final Color hairline;

  final Color primary;
  final Color primaryBright;
  final Color primaryPressed;
  final Color primaryGhost;

  final Color success;
  final Color successGhost;
  final Color caution;
  final Color cautionGhost;
  final Color danger;
  final Color dangerGhost;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color cameraScrim;
  final Color cameraScrimStrong;
  final Color cameraChrome;

  @override
  HarborColors copyWith({
    Color? background,
    Color? backgroundElevated,
    Color? panel,
    Color? card,
    Color? cardActive,
    Color? hairline,
    Color? primary,
    Color? primaryBright,
    Color? primaryPressed,
    Color? primaryGhost,
    Color? success,
    Color? successGhost,
    Color? caution,
    Color? cautionGhost,
    Color? danger,
    Color? dangerGhost,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? cameraScrim,
    Color? cameraScrimStrong,
    Color? cameraChrome,
  }) {
    return HarborColors(
      background: background ?? this.background,
      backgroundElevated: backgroundElevated ?? this.backgroundElevated,
      panel: panel ?? this.panel,
      card: card ?? this.card,
      cardActive: cardActive ?? this.cardActive,
      hairline: hairline ?? this.hairline,
      primary: primary ?? this.primary,
      primaryBright: primaryBright ?? this.primaryBright,
      primaryPressed: primaryPressed ?? this.primaryPressed,
      primaryGhost: primaryGhost ?? this.primaryGhost,
      success: success ?? this.success,
      successGhost: successGhost ?? this.successGhost,
      caution: caution ?? this.caution,
      cautionGhost: cautionGhost ?? this.cautionGhost,
      danger: danger ?? this.danger,
      dangerGhost: dangerGhost ?? this.dangerGhost,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      cameraScrim: cameraScrim ?? this.cameraScrim,
      cameraScrimStrong: cameraScrimStrong ?? this.cameraScrimStrong,
      cameraChrome: cameraChrome ?? this.cameraChrome,
    );
  }

  @override
  HarborColors lerp(ThemeExtension<HarborColors>? other, double t) {
    if (other is! HarborColors) return this;
    return HarborColors(
      background: Color.lerp(background, other.background, t)!,
      backgroundElevated: Color.lerp(backgroundElevated, other.backgroundElevated, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      card: Color.lerp(card, other.card, t)!,
      cardActive: Color.lerp(cardActive, other.cardActive, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryBright: Color.lerp(primaryBright, other.primaryBright, t)!,
      primaryPressed: Color.lerp(primaryPressed, other.primaryPressed, t)!,
      primaryGhost: Color.lerp(primaryGhost, other.primaryGhost, t)!,
      success: Color.lerp(success, other.success, t)!,
      successGhost: Color.lerp(successGhost, other.successGhost, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      cautionGhost: Color.lerp(cautionGhost, other.cautionGhost, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerGhost: Color.lerp(dangerGhost, other.dangerGhost, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      cameraScrim: Color.lerp(cameraScrim, other.cameraScrim, t)!,
      cameraScrimStrong: Color.lerp(cameraScrimStrong, other.cameraScrimStrong, t)!,
      cameraChrome: Color.lerp(cameraChrome, other.cameraChrome, t)!,
    );
  }
}
