import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:equatable/equatable.dart';

/// Every rule about the flash, in one place.
///
/// These rules used to be a `const List` declared inside the Bloc's toggle
/// handler, and that is precisely how the torch went missing: the list stopped
/// at [CaptureFlashMode.always], so nothing the user could press ever reached
/// [CaptureFlashMode.torch] — even though the port accepted it, the plugin
/// mapped it and the chrome had an icon ready for it. A rule that lives inside
/// a handler is a rule nobody tests.
///
/// Four rules, one test group each:
///  1. The button cycles off → auto → always → torch, then back to off.
///  2. Only the torch draws current continuously; the others fire for the
///     length of an exposure.
///  3. The torch never survives an interruption.
///  4. The torch is given a deadline ([torchIdleTimeout]), not trusted to a
///     user remembering.
class FlashPolicy extends Equatable {
  const FlashPolicy({this.torchIdleTimeout = const Duration(minutes: 2)});

  /// The shipping configuration.
  static const FlashPolicy standard = FlashPolicy();

  /// How long the torch may burn without a capture before it switches itself
  /// off.
  ///
  /// The LED is the single largest continuous draw this screen can create —
  /// on most phones larger than the sensor and the preview combined. Two
  /// minutes is long enough to light a document and photograph it, and short
  /// enough that a phone pocketed with the torch lit does not arrive at lunch
  /// flat.
  final Duration torchIdleTimeout;

  /// The order the flash button steps through.
  ///
  /// The torch is last deliberately: it is the only mode with a cost that
  /// continues after the user stops interacting, so it sits one press before
  /// off rather than somewhere a thumb lands on the way past.
  static const List<CaptureFlashMode> cycle = <CaptureFlashMode>[
    CaptureFlashMode.off,
    CaptureFlashMode.auto,
    CaptureFlashMode.always,
    CaptureFlashMode.torch,
  ];

  /// The mode one press of the flash button after [current].
  CaptureFlashMode next(CaptureFlashMode current) {
    final int index = cycle.indexOf(current);
    // A mode that is not in the cycle (a future addition, or a value restored
    // from an older build) steps to the start rather than throwing. The flash
    // button is not a place to crash.
    if (index < 0) return cycle.first;
    return cycle[(index + 1) % cycle.length];
  }

  /// Whether [mode] keeps the LED lit between exposures.
  ///
  /// This is the predicate the battery rules hang off: [CaptureFlashMode.auto]
  /// and [CaptureFlashMode.always] cost one exposure's worth of light, while
  /// [CaptureFlashMode.torch] costs whatever the user forgets to turn off.
  bool drawsContinuously(CaptureFlashMode mode) => mode == CaptureFlashMode.torch;

  /// What [mode] becomes when the sensor comes back after an interruption.
  ///
  /// Pausing disposes the controller, so the LED is already dark by the time
  /// the user returns. Relighting it on resume would be both a surprise and
  /// the most expensive thing this screen can do unattended, so the torch is
  /// downgraded to off. Every other mode is restored exactly as it was —
  /// losing an "always" the user chose is the bug this policy was written to
  /// fix, and over-correcting into "reset everything" would just be the same
  /// bug wearing a different hat.
  CaptureFlashMode afterInterruption(CaptureFlashMode mode) =>
      drawsContinuously(mode) ? CaptureFlashMode.off : mode;

  @override
  List<Object?> get props => <Object?>[torchIdleTimeout];
}
