import 'dart:math' as math;

/// Scale the visible envelope uniformly. Keep relative dynamics; do not clip
/// a percentile of loud bins or stretch each individual bin independently.
List<double> waveformDisplayEnvelope(
  List<double> values, {
  required double duration,
  double windowStart = 0,
  double? windowEnd,
  int maximumBars = 512,
}) {
  final envelope = waveformEnvelope(
    values,
    duration: duration,
    windowStart: windowStart,
    windowEnd: windowEnd,
    maximumBars: maximumBars,
  );
  final peak = envelope.fold<double>(0, math.max);
  if (peak <= 1e-9) return envelope;
  return [for (final value in envelope) value / peak * .92];
}

/// Original editor density: 512 bars, independently of the window width.
/// Detailed caches are reduced only for display; zoom reads the visible bins.
List<double> waveformEnvelope(
  List<double> values, {
  required double duration,
  double windowStart = 0,
  double? windowEnd,
  int maximumBars = 512,
}) {
  if (values.isEmpty || duration <= 0) return const [];
  final start = (windowStart / duration * values.length).floor().clamp(
    0,
    values.length - 1,
  );
  final end = ((windowEnd ?? duration) / duration * values.length).ceil().clamp(
    start + 1,
    values.length,
  );
  final count = math.min(math.max(1, maximumBars), end - start);
  return List.generate(count, (i) {
    final first = start + i * (end - start) ~/ count;
    final last = start + (i + 1) * (end - start) ~/ count;
    var sum = 0.0;
    for (var j = first; j < last; j++) {
      sum += values[j];
    }
    return sum / (last - first);
  }, growable: false);
}
