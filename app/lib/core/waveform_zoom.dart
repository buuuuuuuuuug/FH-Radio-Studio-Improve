import 'dart:math' as math;

/// Never expand a cached envelope bin beyond four logical pixels.
/// Thus zoom detail depends on the cache resolution and the actual viewport,
/// rather than an arbitrary time limit or multiplier per editor.
double minimumWaveformSpan({
  required double duration,
  required int bins,
  required double width,
}) {
  if (duration <= 0 || bins <= 0 || width <= 0) return duration;
  final visibleBins = math.min(bins, (width / 4).ceil());
  return duration * visibleBins / bins;
}
