import 'package:anchorage_harbor/app/theme/harbor_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Colours travel with the theme: one import gives a widget tokens and types.
export 'package:anchorage_harbor/app/theme/harbor_colors.dart';

/// The Harbor type scale.
///
/// Named for role rather than by a generic rung, and deliberately short: the
/// reference design uses six treatments, and a scale with eleven entries is an
/// invitation to invent a twelfth.
@immutable
class HarborTypography extends ThemeExtension<HarborTypography> {
  const HarborTypography({
    this.screenTitle = const TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.2,
    ),

    /// Wide-tracked uppercase eyebrow: "BATCH SYNC PROGRESS".
    this.eyebrow = const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.6,
      height: 1.3,
    ),

    /// File names in the queue.
    this.itemTitle = const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      height: 1.25,
    ),

    /// Sizes, byte counts, secondary metadata.
    this.itemMeta = const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.1,
      height: 1.3,
    ),

    /// Per-item status line: "RETRYING... (ATTEMPT 3/5)".
    this.itemStatus = const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      height: 1.3,
    ),

    /// Button labels and the camera zoom read-outs.
    this.button = const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      height: 1.2,
    ),

    /// Numeric read-outs that must not jitter as digits change.
    this.numeric = const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    ),
  });

  final TextStyle screenTitle;
  final TextStyle eyebrow;
  final TextStyle itemTitle;
  final TextStyle itemMeta;
  final TextStyle itemStatus;
  final TextStyle button;
  final TextStyle numeric;

  @override
  HarborTypography copyWith({
    TextStyle? screenTitle,
    TextStyle? eyebrow,
    TextStyle? itemTitle,
    TextStyle? itemMeta,
    TextStyle? itemStatus,
    TextStyle? button,
    TextStyle? numeric,
  }) {
    return HarborTypography(
      screenTitle: screenTitle ?? this.screenTitle,
      eyebrow: eyebrow ?? this.eyebrow,
      itemTitle: itemTitle ?? this.itemTitle,
      itemMeta: itemMeta ?? this.itemMeta,
      itemStatus: itemStatus ?? this.itemStatus,
      button: button ?? this.button,
      numeric: numeric ?? this.numeric,
    );
  }

  @override
  HarborTypography lerp(ThemeExtension<HarborTypography>? other, double t) {
    if (other is! HarborTypography) return this;
    return HarborTypography(
      screenTitle: TextStyle.lerp(screenTitle, other.screenTitle, t)!,
      eyebrow: TextStyle.lerp(eyebrow, other.eyebrow, t)!,
      itemTitle: TextStyle.lerp(itemTitle, other.itemTitle, t)!,
      itemMeta: TextStyle.lerp(itemMeta, other.itemMeta, t)!,
      itemStatus: TextStyle.lerp(itemStatus, other.itemStatus, t)!,
      button: TextStyle.lerp(button, other.button, t)!,
      numeric: TextStyle.lerp(numeric, other.numeric, t)!,
    );
  }
}

/// A 4dp spacing ladder, so gaps stay in rhythm across screens.
abstract final class HarborSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii, named for the component that owns them.
abstract final class HarborRadius {
  static const Radius card = Radius.circular(14);
  static const Radius thumbnail = Radius.circular(12);
  static const Radius button = Radius.circular(14);
  static const Radius pill = Radius.circular(999);
  static const Radius sheet = Radius.circular(24);
}

/// Builds the app-wide [ThemeData].
///
/// Harbor is dark-only by design, not by omission: it is a camera app, and a
/// light chrome around a live preview both wrecks night vision and shifts the
/// apparent colour of everything the user is framing.
abstract final class HarborTheme {
  static ThemeData build() {
    const HarborColors colors = HarborColors();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: colors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: colors.primary,
        brightness: Brightness.dark,
      ).copyWith(
        surface: colors.background,
        primary: colors.primary,
        error: colors.danger,
      ),
      fontFamily: 'Roboto',
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.cardActive,
        contentTextStyle: TextStyle(color: colors.textPrimary, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(HarborRadius.card),
        ),
      ),
      extensions: const <ThemeExtension<dynamic>>[
        HarborColors(),
        HarborTypography(),
      ],
    );
  }
}

/// `context.harborColors` / `context.harborText` - shorter than the
/// `Theme.of(context).extension<...>()!` incantation at every call site.
extension HarborThemeAccess on BuildContext {
  HarborColors get harborColors =>
      Theme.of(this).extension<HarborColors>() ?? const HarborColors();

  HarborTypography get harborText =>
      Theme.of(this).extension<HarborTypography>() ?? const HarborTypography();
}
