/// Prefer the CLI failure over decoder diagnostics printed before it.
String audioImportErrorDetail(String message) {
  final lines = message
      .replaceFirst(RegExp(r'^FormatException:\s*'), '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final error = RegExp(r'^error:\s*', caseSensitive: false);
  final start = lines.indexWhere(error.hasMatch);
  final relevant = start < 0
      ? lines.where((line) => !line.startsWith('Note:'))
      : lines.skip(start);
  final detail = relevant.join('\n').replaceFirst(error, '');
  return detail.isEmpty ? message.trim() : detail;
}
