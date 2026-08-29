import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the dependency rule for Harbor, the way `ArchitectureTest` does for
/// Perimeter.
///
/// Dart has no compiler-level module boundary at all: `lib/` is one library
/// and any file may import any other. Before the layer-first restructure the
/// rule was "enforced by review", which is another way of saying enforced on
/// whoever happens to be reading. It is enforced here instead — the test walks
/// the sources and fails on the first import that crosses a layer the wrong
/// way, naming the file.
///
/// The rules, one test each:
///  1. `domain/` may import only Dart, Equatable and the failure/result types.
///     This is an **allowlist**, not a denylist, because the innermost ring is
///     the one place where a new plugin sneaking in must be impossible rather
///     than merely unlikely — a denylist only catches the plugins someone
///     thought to name.
///  2. `data/` never reaches up into `presentation/` or `app/`.
///  3. `presentation/` never reaches down into `data/`, apart from two named
///     composition seams (see [_presentationDataSeams]).
///  4. The scan reaches the source tree at all.
void main() {
  group('architecture', () {
    test('the scan actually reaches the source tree', () {
      // Every other assertion here is "no violations found", which is exactly
      // what a walk that reads zero files also reports. This one fails if the
      // layout moves out from under the guard.
      expect(_importsIn('lib/domain').length, greaterThan(15));
      expect(_importsIn('lib/data').length, greaterThan(15));
      expect(_importsIn('lib/presentation').length, greaterThan(15));
    });

    test('the domain imports nothing but Dart, Equatable and core types', () {
      const List<String> allowed = <String>[
        'dart:',
        'package:equatable/',
        'package:anchorage_harbor/domain/',
        'package:anchorage_harbor/core/error/',
        'package:anchorage_harbor/core/result/',
      ];

      final List<String> violations = _importsIn('lib/domain')
          .where((_Import i) => !allowed.any(i.uri.startsWith))
          .map((_Import i) => '${i.file}: ${i.uri}')
          .toList()
        ..sort();

      expect(
        violations,
        isEmpty,
        reason: 'domain/ may import only $allowed — a use case that imports '
            'package:flutter or a plugin can no longer be tested without a '
            'device, which is the whole reason the ports exist',
      );
    });

    test('the data layer does not reach into presentation', () {
      final List<String> violations = _importsIn('lib/data')
          .where((_Import i) =>
              i.uri.startsWith('package:anchorage_harbor/presentation/') ||
              i.uri.startsWith('package:anchorage_harbor/app/'))
          .map((_Import i) => '${i.file}: ${i.uri}')
          .toList()
        ..sort();

      expect(
        violations,
        isEmpty,
        reason: 'an adapter that knows about a screen cannot be reused or '
            'tested in isolation',
      );
    });

    test('the presentation layer does not reach into data', () {
      final List<String> violations = _importsIn('lib/presentation')
          .where((_Import i) =>
              i.uri.startsWith('package:anchorage_harbor/data/') &&
              !_presentationDataSeams.contains(i.file))
          .map((_Import i) => '${i.file}: ${i.uri}')
          .toList()
        ..sort();

      expect(
        violations,
        isEmpty,
        reason: 'Blocs talk to use cases and ports; get_it substitutes the '
            'adapter in di/. Two files are grandfathered — see '
            '_presentationDataSeams — and this test exists so a third does not '
            'appear quietly',
      );
    });
  });
}

/// The two places presentation still touches a concrete adapter, both of them
/// deliberate and both of them narrow.
///
/// * `camera_preview_page.dart` needs the plugin's own `CameraController` to
///   hand to `CameraPreview`. There is no way to render a platform texture
///   from behind a port — the widget *is* the adapter.
/// * `camera_settings_sheet.dart` drives `MockUploadApi`'s canned-response
///   switcher, a demonstration affordance over a component that only exists
///   because the brief supplies no server. It moved here from
///   `upload_manager_page.dart` when that screen was brought back in line with
///   the reference design, whose bottom bar carries one button and nothing
///   else; the count of seams did not grow.
///
/// They are listed by name rather than allowed by pattern so that adding a
/// third is a decision someone has to write down here, not a diff nobody
/// notices.
const Set<String> _presentationDataSeams = <String>{
  'camera_preview_page.dart',
  'camera_settings_sheet.dart',
};

class _Import {
  const _Import(this.file, this.uri);

  final String file;
  final String uri;
}

final RegExp _importPattern = RegExp("^import '([^']+)'");

List<_Import> _importsIn(String directory) {
  final Directory root = Directory(directory);
  if (!root.existsSync()) {
    fail('architecture scan could not find $directory from ${Directory.current.path}');
  }

  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((File file) => file.path.endsWith('.dart'))
      .expand((File file) {
    final String name = file.uri.pathSegments.last;
    return file
        .readAsLinesSync()
        .map(_importPattern.firstMatch)
        .whereType<RegExpMatch>()
        .map((RegExpMatch match) => _Import(name, match.group(1)!));
  }).toList();
}
