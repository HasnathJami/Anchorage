import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';

/// The three states that actually matter when asking for a permission.
///
/// `permission_handler` reports six; collapsing them here means the UI has
/// three cases to render instead of six, and the distinction it keeps is the
/// only one that changes what the user must do next.
enum PermissionOutcome {
  /// Granted. Proceed.
  granted,

  /// Refused, but the system dialog will appear again. Offer to ask.
  denied,

  /// Refused for good, or blocked by policy. Only Settings can fix it.
  blocked,
}

/// Runtime permissions, behind a port.
///
/// `permission_handler` is a plugin with a platform channel, so a Bloc that
/// called it directly could not be unit-tested. Every permission decision in
/// Harbor goes through this interface, and tests supply a fake that answers
/// instantly.
///
/// The port lives in `domain/` and its `permission_handler` implementation in
/// `data/services/`. They were one file until the layer-first restructure —
/// which meant the plugin import travelled with the interface into every
/// consumer, the exact coupling this port exists to prevent.
abstract interface class PermissionGateway {
  Future<PermissionOutcome> requestCamera();

  Future<PermissionOutcome> cameraStatus();

  /// Opens the OS settings page for this app.
  Future<bool> openSettings();
}

/// Translates an outcome into the failure the domain speaks.
extension PermissionOutcomeX on PermissionOutcome {
  Result<void> toResult(AppPermission permission) => switch (this) {
        PermissionOutcome.granted => const Result<void>.success(null),
        PermissionOutcome.denied =>
          Result<void>.failure(PermissionDeniedFailure(permission)),
        PermissionOutcome.blocked =>
          Result<void>.failure(PermissionPermanentlyDeniedFailure(permission)),
      };
}
