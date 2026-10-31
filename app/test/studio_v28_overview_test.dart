import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_overview.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_painter.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'refinement overview tracks zoom and panning independently from main playback',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      final n = f.container.read(replaceEditorProvider('p1').notifier);
      final markers = {...n.state.markerSeconds};
      final dirty = n.state.dirty;
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      );
      await t.pumpAndSettle();
      final button = find.byKey(const ValueKey('editor-manual-refine-tl'));
      await Scrollable.ensureVisible(t.element(button), alignment: .5);
      await t.pumpAndSettle();
      await t.tap(button);
      await t.pumpAndSettle();
      final overview = find.byKey(const ValueKey('manual-waveform-overview'));
      WaveformOverview strip() => t.widget<WaveformOverview>(overview);
      ManualFocusWaveform wave() =>
          t.widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform));
      void check() {
        expect(strip().windowStart, wave().windowStart);
        expect(strip().windowEnd, wave().windowEnd ?? wave().duration);
        final paint = t.widget<CustomPaint>(
          find.descendant(
            of: overview,
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is ZoomStripPainter,
            ),
          ),
        );
        expect(
          (paint.painter! as ZoomStripPainter).windowStart,
          wave().windowStart,
        );
      }

      expect(strip().windowStart, 0);
      expect(strip().windowEnd, strip().duration);
      await t.tap(find.byKey(const ValueKey('manual-zoom-in')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('manual-zoom-in')));
      await t.pumpAndSettle();
      final span = strip().windowEnd - strip().windowStart;
      final before = strip().windowStart;
      check();
      await t.drag(overview, const Offset(45, 0));
      await t.pumpAndSettle();
      expect(strip().windowStart, greaterThan(before));
      expect(strip().windowEnd - strip().windowStart, closeTo(span, 1e-6));
      check();
      await t.tapAt(t.getTopRight(overview) + const Offset(-1, 19));
      await t.pumpAndSettle();
      expect(strip().windowEnd, closeTo(strip().duration, 1e-6));
      check();
      final end = strip().windowEnd;
      n.setPlaying(true);
      n.setPlayhead(0);
      await t.pumpAndSettle();
      expect(strip().windowEnd, end);
      expect(strip().windowStart, closeTo(strip().duration - span, 1e-6));
      check();
      n.setPlaying(false);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(n.state.markerSeconds, markers);
      expect(n.state.dirty, dirty);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('overview full range and empty audio ignore panning safely', (
    t,
  ) async {
    for (final duration in [0.0, 200.0]) {
      final starts = <double>[];
      await t.pumpWidget(
        helpers.app(
          Center(
            child: SizedBox(
              width: 350,
              child: WaveformOverview(
                bars: WaveformBars.fromValues(const []),
                duration: duration,
                windowStart: 0,
                windowEnd: duration,
                onWindowStart: starts.add,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byType(WaveformOverview));
      await t.drag(find.byType(WaveformOverview), const Offset(80, 0));
      await t.pumpAndSettle();
      expect(starts, isEmpty);
      expect(t.takeException(), isNull);
    }
  });
  testWidgets('overview fits dark refinement in short and narrow windows', (
    t,
  ) async {
    t.view.physicalSize = const Size(900, 660);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = await fixture.fixture();
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.dark,
            accent: AppAccent.cyan,
          ),
          home: const Scaffold(
            body: ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final button = find.byKey(const ValueKey('editor-manual-refine-tl'));
    await Scrollable.ensureVisible(t.element(button), alignment: .5);
    await t.pumpAndSettle();
    await t.tap(button);
    await t.pumpAndSettle();
    for (final width in [900.0, 720.0]) {
      t.view.physicalSize = Size(width, 660);
      await t.pumpAndSettle();
      final overview = find.byKey(const ValueKey('manual-waveform-overview'));
      await Scrollable.ensureVisible(t.element(overview), alignment: .5);
      await t.pumpAndSettle();
      expect(t.getSize(overview).height, 32);
      expect(t.getRect(overview).left, greaterThanOrEqualTo(0));
      expect(t.getRect(overview).right, lessThanOrEqualTo(width));
      expect(t.takeException(), isNull);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
  });
}
