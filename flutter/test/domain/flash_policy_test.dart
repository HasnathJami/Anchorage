import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/flash_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const FlashPolicy policy = FlashPolicy.standard;

  group('the flash button cycle', () {
    test('reaches the torch', () {
      // The bug this policy was written for: the cycle used to stop at
      // `always`, so the torch was unreachable from the UI even though the
      // port, the plugin mapping and the icon all supported it.
      expect(
        FlashPolicy.cycle,
        contains(CaptureFlashMode.torch),
      );
    });

    test('steps off to auto to always to torch and back to off', () {
      CaptureFlashMode mode = CaptureFlashMode.off;
      final List<CaptureFlashMode> visited = <CaptureFlashMode>[];

      for (int press = 0; press < FlashPolicy.cycle.length; press++) {
        mode = policy.next(mode);
        visited.add(mode);
      }

      expect(
        visited,
        <CaptureFlashMode>[
          CaptureFlashMode.auto,
          CaptureFlashMode.always,
          CaptureFlashMode.torch,
          CaptureFlashMode.off,
        ],
      );
    });

    test('returns to the start of the cycle from an unrecognised mode', () {
      // Defensive: a mode restored from an older build, or one added to the
      // enum but not the cycle, must not throw. The flash button is not a
      // place to crash.
      expect(
        const FlashPolicy().next(CaptureFlashMode.torch),
        CaptureFlashMode.off,
      );
    });
  });

  group('continuous draw', () {
    test('only the torch keeps the LED lit between exposures', () {
      expect(policy.drawsContinuously(CaptureFlashMode.torch), isTrue);

      for (final CaptureFlashMode mode in <CaptureFlashMode>[
        CaptureFlashMode.off,
        CaptureFlashMode.auto,
        CaptureFlashMode.always,
      ]) {
        expect(
          policy.drawsContinuously(mode),
          isFalse,
          reason: '$mode costs one exposure, not an open-ended burn',
        );
      }
    });
  });

  group('surviving an interruption', () {
    test('the torch does not come back lit', () {
      expect(
        policy.afterInterruption(CaptureFlashMode.torch),
        CaptureFlashMode.off,
      );
    });

    test('every other mode is restored exactly as it was', () {
      // Over-correcting into "reset everything on resume" would just be the
      // original bug — a chosen flash mode silently lost — wearing a hat.
      for (final CaptureFlashMode mode in <CaptureFlashMode>[
        CaptureFlashMode.off,
        CaptureFlashMode.auto,
        CaptureFlashMode.always,
      ]) {
        expect(policy.afterInterruption(mode), mode);
      }
    });
  });

  group('the torch deadline', () {
    test('is finite by default', () {
      // A torch with no deadline is a flat battery in a pocket. The exact
      // number is a product call; that there *is* one is the rule.
      expect(policy.torchIdleTimeout, greaterThan(Duration.zero));
      expect(policy.torchIdleTimeout, lessThanOrEqualTo(const Duration(minutes: 5)));
    });
  });
}
