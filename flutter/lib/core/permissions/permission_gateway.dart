import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

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
abstract interface class PermissionGateway {
  Future<PermissionOutcome> requestCamera();

  Future<PermissionOutcome> cameraStatus();

  /// Opens the OS settings page for this app.
  Future<bool> openSettings();
}

class PermissionHandlerGateway implements PermissionGateway {
  const PermissionHandlerGateway();

  @override
  Future<PermissionOutcome> requestCamera() async =>
      _map(await ph.Permission.camera.request());

  @override
  Future<PermissionOutcome> cameraStatus() async =>
      _map(await ph.Permission.camera.status);

  @override
  Future<bool> openSettings() => ph.openAppSettings();

  PermissionOutcome _map(ph.PermissionStatus status) {
    if (status.isGranted || status.isLimited) return PermissionOutcome.granted;
    // `restricted` (parental controls / MDM) and `permanentlyDenied` both mean
    // the dialog is never coming back, so they collapse to the same remedy.
    if (status.isPermanentlyDenied || status.isRestricted) {
      return PermissionOutcome.blocked;
    }
    return PermissionOutcome.denied;
  }
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
