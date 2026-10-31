import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/waveform_cache.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/editor_timecode.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/track_timing_state.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'editor_playlist_upgrade_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'editor milliseconds round across minute boundaries without changing global display',
    () {
      expect(formatEditorTimecode(59.9996), '1:00.000');
      expect(formatEditorTimecode(83.456), '1:23.456');
      expect(formatEditorTimecode(0), '0:00.000');
      expect(formatTimecode(83.456), '1:23.46');
    },
  );
  test(
    'saving a loaded song preserves notifier, waveform, zoom and drafts',
    () async {
      final f = await fixtures.fixture();
      final c = f.container;
      c.read(editorOptionsProvider.notifier).update(manualOnly: true);
      final source =
          '${f.dir.path}${Platform.pathSeparator}sources${Platform.pathSeparator}song.wav';
      final id = realTrackIdForPath(source);
      final provider = replaceEditorProvider(id);
      final sub = c.listen(provider, (_, _) {});
      addTearDown(sub.close);
      await WaveformCache.write(f.dir.path, source, {
        'duration_sec': 180,
        'sample_rate': 48000,
        'samples': 8640000,
        'grid': {
          'beats': [0, .5, 1, 1.55],
        },
        'waveform': {
          'bins': List.generate(
            8192,
            (i) => {'norm_peak': .3 + (i % 7) / 10, 'norm_rms': .3},
          ),
        },
      });
      final n = c.read(provider.notifier);
      await n.loadWaveform();
      n.editTime(GroupKind.td, FineTarget.point, 12.345);
      n.setPlayhead(90);
      n.zoomIn();
      for (final kind in GroupKind.values) {
        n.setConfirmed(kind, true);
      }
      final before = c.read(provider);
      expect(before.ai.waveformPeaks.length, 8192);
      expect(before.ai.beats, [0, .5, 1, 1.55]);
      n.saveToProject();
      await Future<void>.delayed(Duration.zero);
      expect(identical(n, c.read(provider.notifier)), isTrue);
      final after = c.read(provider);
      expect(after.ai.waveformPeaks, before.ai.waveformPeaks);
      expect(after.ai.beats, before.ai.beats);
      expect(after.zoomStart, before.zoomStart);
      expect(after.zoomEnd, before.zoomEnd);
      expect(after.markerSeconds, before.markerSeconds);
      expect(after.saved, isTrue);
      expect(after.dirty, isFalse);
      expect(after.track.configured, isTrue);
      expect(
        c.read(trackTimingProvider.notifier).configForPath(source)!.markersSec,
        after.markerSeconds,
      );
    },
  );
  test(
    'expansion defaults off and switching it preserves stored timings',
    () async {
      final f = await fixtures.fixture();
      final c = f.container;
      expect(c.read(editorOptionsProvider).expansionEnabled, isFalse);
      c.read(editorOptionsProvider.notifier).update(expansionEnabled: true);
      c.invalidate(editorOptionsProvider);
      expect(c.read(editorOptionsProvider).expansionEnabled, isTrue);
      c.read(editorOptionsProvider.notifier).update(expansionEnabled: false);
      c.invalidate(editorOptionsProvider);
      expect(c.read(editorOptionsProvider).expansionEnabled, isFalse);
    },
  );
  testWidgets('holding a button waits then repeats and stops on release', (
    tester,
  ) async {
    var clicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: RmButton(repeat: true, onPressed: () => clicks++, label: '+10'),
        ),
      ),
    );
    final button = find.text('+10');
    await tester.tap(button);
    await tester.pump();
    expect(clicks, 1);
    final hold = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 450));
    expect(clicks, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(clicks, greaterThan(2));
    final repeated = clicks;
    await hold.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(clicks, repeated);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'zoomed manual waveform maps clicks to the visible absolute time',
    (tester) async {
      double? placed, seeked;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: ManualFocusWaveform(
              bars: WaveformBars.fromValues(List.filled(8192, .4)),
              beats: const [10, 10.5, 11, 11.5],
              segments: const [],
              duration: 180,
              windowStart: 60,
              windowEnd: 90,
              accent: Colors.blue,
              handles: const [],
              free: true,
              locked: false,
              onPlace: (seconds, {required isMove}) => placed = seconds,
              onSeek: (seconds) => seeked = seconds,
            ),
          ),
        ),
      );
      final waveform = find.byType(ManualFocusWaveform);
      final rect = tester.getRect(waveform);
      await tester.tapAt(Offset(rect.left + rect.width * .25, rect.top + 65));
      expect(seeked, closeTo(67.5, .01));
      expect(placed, isNull);
      final right = await tester.startGesture(
        Offset(rect.left + rect.width * .25, rect.top + 65),
        buttons: 2,
      );
      await right.up();
      expect(placed, closeTo(67.5, .01));
      expect(tester.takeException(), isNull);
    },
  );
}
