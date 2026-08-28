import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// [PermissionGateway] backed by the `permission_handler` plugin.
///
/// This is the only file in the app that imports `permission_handler`, which
/// is what keeps the plugin's six-state model — and its platform channel — out
/// of everything that merely needs to know whether the camera may be opened.
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
