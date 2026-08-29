import 'package:anchorage_harbor/core/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bytes', () {
    test('renders each unit at a sensible precision', () {
      expect(Formatters.bytes(0), '0 B');
      expect(Formatters.bytes(512), '512 B');
      expect(Formatters.bytes(2 * 1024), '2.0 KB');
      expect(Formatters.bytes(482 * 1024 * 1024), '482 MB');
    });

    test('drops the decimal once the number is large enough not to need it', () {
      // 1.2 GB keeps its decimal; 482 MB does not.
      expect(Formatters.bytes((1.2 * 1024 * 1024 * 1024).round()), '1.2 GB');
      expect(Formatters.bytes(12 * 1024 * 1024), '12 MB');
    });

    test('a negative or zero size is not rendered as gibberish', () {
      expect(Formatters.bytes(-1), '0 B');
    });
  });

  group('throughput', () {
    test('appends a rate suffix', () {
      expect(Formatters.throughput(12 * 1024 * 1024), '12 MB/s');
    });

    test('idle reads as a dash rather than 0 B/s', () {
      expect(Formatters.throughput(0), '--');
    });
  });

  test('transferred renders the batch sub-line', () {
    expect(
      Formatters.transferred(
        (2.4 * 1024 * 1024 * 1024).round(),
        (3.2 * 1024 * 1024 * 1024).round(),
      ),
      '2.4 GB / 3.2 GB Uploaded',
    );
  });

  group('zoom', () {
    test('whole numbers lose the decimal', () {
      expect(Formatters.zoom(1), '1x');
      expect(Formatters.zoom(2), '2x');
    });

    test('fractional zoom keeps one decimal', () {
      expect(Formatters.zoom(0.5), '0.5x');
      expect(Formatters.zoom(2.3), '2.3x');
    });
  });

  group('fileName', () {
    test('short names are untouched', () {
      expect(Formatters.fileName('SHORT.jpg'), 'SHORT.jpg');
    });

    test('long names are truncated in the middle, keeping the extension', () {
      final String result =
          Formatters.fileName('RAW_DATA_NODE_091_EXTENDED_CAPTURE.dat');

      expect(result.length, lessThanOrEqualTo(28));
      expect(result, contains('...'));
      expect(result, endsWith('.dat'));
      expect(result, startsWith('RAW_DATA'));
    });
  });

  group('fileNameParts', () {
    test('splits the stem from the extension', () {
      expect(
        Formatters.fileNameParts('RAW_DATA_NODE_081.dat'),
        ('RAW_DATA_NODE_081', '.dat'),
      );
    });

    test('a name with no extension keeps everything in the stem', () {
      expect(Formatters.fileNameParts('MANIFEST'), ('MANIFEST', ''));
    });

    test('a trailing dot is not an extension', () {
      // Otherwise the row would render an orphaned grey full stop.
      expect(Formatters.fileNameParts('ODD.'), ('ODD.', ''));
    });

    test('a leading dot is the whole name, not an extension', () {
      expect(Formatters.fileNameParts('.gitkeep'), ('.gitkeep', ''));
    });

    test('only the last dot splits a multi-part name', () {
      expect(
        Formatters.fileNameParts('SCAN.2026.08.tar.gz'),
        ('SCAN.2026.08.tar', '.gz'),
      );
    });
  });

  test('attempts renders the retry counter', () {
    expect(Formatters.attempts(3, 5), '3/5');
  });
}
