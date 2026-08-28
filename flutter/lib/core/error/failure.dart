import 'package:equatable/equatable.dart';

/// The complete, closed taxonomy of failures Anchorage Harbor can experience.
///
/// Two properties make this worth its weight:
///
///  1. **Every case is actionable.** Each one maps to a *different* thing the
///     app or the user should do next - retry now, wait for a network, ask for
///     a permission, or give up and tell someone. A single `AppException` with
///     a message string could not drive any of that.
///  2. **It is exhaustive.** `switch` expressions over these types are checked
///     by the analyser, so a new failure mode cannot slip through the sync
///     engine silently defaulting to "retry forever".
sealed class Failure extends Equatable {
  const Failure({this.cause});

  /// The originating error, kept for logs. Never shown to a user.
  final Object? cause;

  @override
  List<Object?> get props => <Object?>[runtimeType, cause];
}

// ---------------------------------------------------------------- permissions

/// The user has not granted a permission, and the OS will still ask.
final class PermissionDeniedFailure extends Failure {
  const PermissionDeniedFailure(this.permission, {super.cause});

  final AppPermission permission;

  @override
  List<Object?> get props => <Object?>[...super.props, permission];
}

/// The OS will no longer show the dialog; only Settings can resolve it.
final class PermissionPermanentlyDeniedFailure extends Failure {
  const PermissionPermanentlyDeniedFailure(this.permission, {super.cause});

  final AppPermission permission;

  @override
  List<Object?> get props => <Object?>[...super.props, permission];
}

/// Device policy blocks the permission outright (managed devices).
final class PermissionRestrictedFailure extends Failure {
  const PermissionRestrictedFailure(this.permission, {super.cause});

  final AppPermission permission;

  @override
  List<Object?> get props => <Object?>[...super.props, permission];
}

enum AppPermission { camera, photos, notifications }

// -------------------------------------------------------------------- camera

/// No usable camera on this device (or all of them are in use).
final class CameraUnavailableFailure extends Failure {
  const CameraUnavailableFailure({super.cause});
}

/// The camera was initialised but the platform rejected an operation.
final class CameraOperationFailure extends Failure {
  const CameraOperationFailure(this.operation, {super.cause});

  final String operation;

  @override
  List<Object?> get props => <Object?>[...super.props, operation];
}

/// The camera was taken away mid-session (a call came in, or the app was
/// backgrounded and the OS reclaimed the sensor).
final class CameraInterruptedFailure extends Failure {
  const CameraInterruptedFailure({super.cause});
}

// ------------------------------------------------------------------- storage

/// Local database or file-system write failed.
final class StorageWriteFailure extends Failure {
  const StorageWriteFailure({super.cause});
}

/// Local database or file-system read failed.
final class StorageReadFailure extends Failure {
  const StorageReadFailure({super.cause});
}

/// The queue points at a file that is no longer on disk. Terminal: retrying
/// cannot conjure the bytes back, so the task must be surfaced, not looped.
final class MissingArtifactFailure extends Failure {
  const MissingArtifactFailure(this.path, {super.cause});

  final String path;

  @override
  List<Object?> get props => <Object?>[...super.props, path];
}

// ------------------------------------------------------------------ transport

/// No usable network at all. Retryable, but only once the link returns.
final class NoConnectionFailure extends Failure {
  const NoConnectionFailure({super.cause});
}

/// A connection exists but is too slow to finish the transfer. Retryable, and
/// distinguished from [NoConnectionFailure] because the remedy differs: wait
/// for a *better* link rather than for *any* link.
final class LowBandwidthFailure extends Failure {
  const LowBandwidthFailure({this.observedBytesPerSecond, super.cause});

  final int? observedBytesPerSecond;

  @override
  List<Object?> get props => <Object?>[...super.props, observedBytesPerSecond];
}

/// The request was accepted but did not complete in time.
final class TimeoutFailure extends Failure {
  const TimeoutFailure({super.cause});
}

/// The server answered with an error. [isRetryable] separates a 503 (worth
/// another attempt) from a 400 (never worth another attempt).
final class ServerFailure extends Failure {
  const ServerFailure(this.statusCode, {this.isRetryable = true, super.cause});

  final int statusCode;
  final bool isRetryable;

  @override
  List<Object?> get props => <Object?>[...super.props, statusCode, isRetryable];
}

/// The escape hatch. Its existence is deliberate: an adapter meeting a
/// genuinely unknown error must still return a typed failure rather than throw.
final class UnexpectedFailure extends Failure {
  const UnexpectedFailure({this.detail, super.cause});

  final String? detail;

  @override
  List<Object?> get props => <Object?>[...super.props, detail];
}

/// Whether another attempt could plausibly succeed.
///
/// This single predicate is what stops the sync engine from hammering a
/// permanently broken task forever, and from abandoning a task that is only
/// waiting for a train to leave a tunnel.
extension FailureRetryability on Failure {
  bool get isRetryable => switch (this) {
        NoConnectionFailure() => true,
        LowBandwidthFailure() => true,
        TimeoutFailure() => true,
        ServerFailure(:final isRetryable) => isRetryable,
        StorageReadFailure() => true,
        StorageWriteFailure() => true,
        MissingArtifactFailure() => false,
        PermissionDeniedFailure() => false,
        PermissionPermanentlyDeniedFailure() => false,
        PermissionRestrictedFailure() => false,
        CameraUnavailableFailure() => false,
        CameraOperationFailure() => false,
        CameraInterruptedFailure() => false,
        UnexpectedFailure() => false,
      };

  /// True when the only thing missing is a network - used to park a task in
  /// `waitingForConnection` instead of counting it as a failed attempt.
  bool get isConnectivityRelated =>
      this is NoConnectionFailure || this is LowBandwidthFailure;
}
