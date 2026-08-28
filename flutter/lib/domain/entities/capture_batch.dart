import 'package:equatable/equatable.dart';

/// One photograph, already written to the app's private storage.
///
/// The file is on disk before this object exists. That ordering is the whole
/// durability story: a shot the user has seen the shutter fire on is never
/// held only in memory, so a crash between capture and upload loses nothing.
class CapturedShot extends Equatable {
  const CapturedShot({
    required this.id,
    required this.filePath,
    required this.displayName,
    required this.sizeBytes,
    required this.capturedAt,
    required this.lensLabel,
    required this.zoomLevel,
  });

  final String id;
  final String filePath;
  final String displayName;
  final int sizeBytes;
  final DateTime capturedAt;

  /// Which physical lens took it - kept for the audit trail and EXIF-less
  /// debugging of "why is this frame wider than the others?".
  final String lensLabel;

  final double zoomLevel;

  @override
  List<Object?> get props =>
      <Object?>[id, filePath, displayName, sizeBytes, capturedAt, lensLabel, zoomLevel];
}

/// A working set of shots the user is assembling before handing it to the
/// sync engine.
///
/// Batching is a first-class concept rather than a UI grouping: it is what
/// lets someone photograph a whole site with no signal and hand over one
/// coherent unit when they reach a connection.
class CaptureBatch extends Equatable {
  const CaptureBatch({
    required this.id,
    required this.startedAt,
    this.shots = const <CapturedShot>[],
  });

  final String id;
  final DateTime startedAt;
  final List<CapturedShot> shots;

  int get count => shots.length;

  bool get isEmpty => shots.isEmpty;

  bool get isNotEmpty => shots.isNotEmpty;

  int get totalBytes =>
      shots.fold(0, (int sum, CapturedShot shot) => sum + shot.sizeBytes);

  /// The most recent shot - the one shown in the corner thumbnail.
  CapturedShot? get latest => shots.isEmpty ? null : shots.last;

  CaptureBatch add(CapturedShot shot) =>
      CaptureBatch(id: id, startedAt: startedAt, shots: <CapturedShot>[...shots, shot]);

  CaptureBatch removeById(String shotId) => CaptureBatch(
        id: id,
        startedAt: startedAt,
        shots: shots.where((CapturedShot shot) => shot.id != shotId).toList(),
      );

  @override
  List<Object?> get props => <Object?>[id, startedAt, shots];
}
