import 'dart:math';

/// Presentation-only formatting, kept out of both the Bloc (so state stays
/// numeric and testable) and the widgets (so the rules are asserted once).
abstract final class Formatters {
  static const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB'];

  /// "482 MB", "1.2 GB", "2.1 KB".
  ///
  /// Uses 1024-based units, matching what every file manager on the device
  /// shows, and drops the decimal below 10 units where it would be noise.
  static String bytes(int value) {
    if (value <= 0) return '0 B';

    final int exponent = min(
      (log(value) / log(1024)).floor(),
      _units.length - 1,
    );
    final double scaled = value / pow(1024, exponent);

    final String number = exponent == 0
        ? scaled.toStringAsFixed(0)
        : (scaled >= 10 ? scaled.toStringAsFixed(0) : scaled.toStringAsFixed(1));

    return '$number ${_units[exponent]}';
  }

  /// "12 MB/s". Zero is rendered as an em dash rather than "0 B/s", which
  /// reads as a broken transfer rather than an idle one.
  static String throughput(int bytesPerSecond) =>
      bytesPerSecond <= 0 ? '--' : '${bytes(bytesPerSecond)}/s';

  /// "2.4 GB / 3.2 GB Uploaded" - the sub-line under the batch progress bar.
  static String transferred(int uploaded, int total) =>
      '${bytes(uploaded)} / ${bytes(total)} Uploaded';

  /// "0.5x", "1x", "2.3x" - zoom pills and the slider read-out.
  static String zoom(double value) {
    final String text = value >= 10
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);
    return '${text}x';
  }

  /// Trims a long file name for a single line: "RAW_DATA_NO...091.dat".
  ///
  /// Truncates in the *middle* rather than the end, because the informative
  /// parts of a generated file name are its prefix and its extension - a
  /// trailing ellipsis throws away exactly the half that identifies the type.
  static String fileName(String value, {int maxLength = 28}) {
    if (value.length <= maxLength) return value;

    const String ellipsis = '...';
    final int keep = maxLength - ellipsis.length;
    final int head = (keep / 2).ceil();
    final int tail = keep - head;

    return '${value.substring(0, head)}$ellipsis${value.substring(value.length - tail)}';
  }

  /// "3/5" for the retry attempt counter.
  static String attempts(int attempt, int maxAttempts) => '$attempt/$maxAttempts';
}
