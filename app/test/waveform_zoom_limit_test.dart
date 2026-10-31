import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/waveform_zoom.dart';

void main() {
  test(
    'zoom detail follows envelope resolution and viewport, independent of duration',
    () {
      for (final duration in [.5, 10.0, 240.0]) {
        for (final width in [400.0, 900.0, 2400.0]) {
          for (final bins in [4096, 8192]) {
            final span = minimumWaveformSpan(
              duration: duration,
              bins: bins,
              width: width,
            );
            final pitch = width / (span / duration * bins);
            expect(pitch, lessThanOrEqualTo(4.0));
            expect(pitch, greaterThan(3.95));
          }
        }
      }
      expect(minimumWaveformSpan(duration: 1, bins: 10, width: 900), 1);
    },
  );
}
