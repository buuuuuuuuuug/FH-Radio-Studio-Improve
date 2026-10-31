import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/timing_import_dialog.dart';
import 'package:fh_radio_studio/widgets/timing_export_dialog.dart';
import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;
import 'playlist_double_edit_test.dart' as routing;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'zoomed playback follows forward, loop jumps and edges without editing markers',
    () async {
      final f = await fixture.fixture();
      final n = f.container.read(replaceEditorProvider('p1').notifier);
      n.setPlayhead(100);
      n.zoomIn();
      n.zoomIn();
      n.zoomIn();
      final span = n.state.zoomEnd - n.state.zoomStart;
      final markers = {...n.state.markerSeconds};
      final dirty = n.state.dirty;
      n.setPlaying(true);
      n.setPlayhead(150);
      expect(
        n.state.zoomStart,
        closeTo(
          (150 - span * .1).clamp(0, n.state.ai.durationSec - span),
          1e-6,
        ),
      );
      final stationary = (n.state.zoomStart, n.state.zoomEnd);
      n.setPlayhead(151);
      expect((n.state.zoomStart, n.state.zoomEnd), stationary);
      expect(n.state.zoomEnd - n.state.zoomStart, closeTo(span, 1e-6));
      n.setPlayhead(n.state.ai.durationSec);
      expect(n.state.zoomEnd, n.state.ai.durationSec);
      n.setPlayhead(0);
      expect(n.state.zoomStart, 0);
      expect(n.state.zoomEnd, closeTo(span, 1e-6));
      n.setPlaying(false);
      final before = (n.state.zoomStart, n.state.zoomEnd);
      n.setPlayhead(130);
      expect((n.state.zoomStart, n.state.zoomEnd), before);
      expect(n.state.markerSeconds, markers);
      expect(n.state.dirty, dirty);
    },
  );
  testWidgets('manual waveform ignores main playback and keeps its zoom', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = await fixture.fixture();
    final n = f.container.read(replaceEditorProvider('p1').notifier);
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
    await t.tap(find.byKey(const ValueKey('manual-zoom-in')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('manual-zoom-in')));
    await t.pumpAndSettle();
    ManualFocusWaveform wave() =>
        t.widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform));
    final span = wave().windowEnd! - wave().windowStart;
    final handles = wave().handles.map((h) => h.t).toList();
    n.setPlaying(true);
    await t.pumpAndSettle();
    final previousStart = wave().windowStart;
    n.setPlayhead(wave().windowEnd! - span * .05);
    await t.pumpAndSettle();
    expect(wave().windowStart, previousStart);
    final stationary = (wave().windowStart, wave().windowEnd);
    n.setPlayhead(wave().windowStart + span * .5);
    await t.pumpAndSettle();
    expect((wave().windowStart, wave().windowEnd), stationary);
    expect(wave().windowEnd! - wave().windowStart, closeTo(span, 1e-6));
    n.setPlayhead(0);
    await t.pumpAndSettle();
    expect(wave().windowStart, previousStart);
    expect(wave().handles.map((h) => h.t).toList(), handles);
    n.setPlaying(false);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'transfer dialogs share accent and support Escape after interacting',
    (t) async {
      final f = await fixture.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const Column(
              children: [TimingImportButton(), TimingExportButton()],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('导入时间点'));
      await t.pumpAndSettle();
      expect(find.text('Esc 关闭'), findsOneWidget);
      expect(
        t.widget<Dialog>(find.byType(Dialog)).shape,
        isA<RoundedRectangleBorder>(),
      );
      final box = find.byType(Checkbox).first;
      final ctx = t.element(box);
      expect(Theme.of(ctx).colorScheme.primary, ctx.rm.accent.base);
      await t.tap(find.byType(Checkbox).last);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TimingImportDialog), findsNothing);
      await t.tap(find.text('导出时间点'));
      await t.pumpAndSettle();
      expect(find.byType(TimingExportDialog), findsOneWidget);
      expect(find.text('Esc 关闭'), findsOneWidget);
      expect(find.textContaining('TL-A'), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(TimingExportDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('idle timing import dismisses when clicking outside', (t) async {
    final f = await fixture.fixture();
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: helpers.app(const TimingImportButton()),
      ),
    );
    await t.tap(find.text('导入时间点'));
    await t.pumpAndSettle();
    expect(find.byType(TimingImportDialog), findsOneWidget);
    await t.tapAt(const Offset(8, 8));
    await t.pumpAndSettle();
    expect(find.byType(TimingImportDialog), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('busy timing import rejects Escape and outside clicks', (
    t,
  ) async {
    final f = await fixture.fixture();
    final pending = Completer<CliRunResult>();
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: ProviderScope(
          overrides: [
            timingImportFilePickerProvider.overrideWithValue(
              () async => "C:/fixtures/points.csv",
            ),
            timingImportRunnerProvider.overrideWithValue(
              (_, args, input) => pending.future,
            ),
          ],
          child: helpers.app(const TimingImportButton()),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('导入时间点'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('timing-import-file')));
    await t.pumpAndSettle();
    await t.tap(find.text('预览匹配'));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byType(TimingImportDialog), findsOneWidget);
    await t.tapAt(const Offset(8, 8));
    await t.pump();
    expect(find.byType(TimingImportDialog), findsOneWidget);
    pending.complete(
      CliRunResult(
        commandLine: 'test',
        exitCode: 0,
        stdout: '{"rows":[],"ready_count":0}',
        stderr: '',
      ),
    );
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byType(TimingImportDialog), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'table labels align with row cells and every separator has the same inset',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      final id = f.container.read(realPoolTracksProvider).first.id;
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(const CustomPoolScreen()),
        ),
      );
      await t.pumpAndSettle();
      Future<void> check() async {
        final columns =
            [
                  'song',
                  'assignment',
                  'configuration',
                  'added',
                  'modified',
                  'preview',
                  'actions',
                ]
                .where(
                  (id) => find
                      .byKey(ValueKey('pool-column-title-$id'))
                      .evaluate()
                      .isNotEmpty,
                )
                .toList();
        for (final idColumn in columns) {
          final label = find.byKey(ValueKey('pool-column-title-$idColumn'));
          final value = find.byKey(ValueKey('pool-value-$idColumn:$id')).first;
          expect(
            t.getTopLeft(label).dx,
            closeTo(t.getTopLeft(value).dx, 1),
            reason: idColumn,
          );
        }
        for (var i = 0; i < columns.length - 1; i++) {
          final grip = find.byKey(ValueKey('pool-column-grip-${columns[i]}'));
          final label = find.byKey(
            ValueKey('pool-column-title-${columns[i + 1]}'),
          );
          expect(
            t.getTopLeft(label).dx - t.getCenter(grip).dx,
            closeTo(8, 1),
            reason: columns[i],
          );
        }
        expect(t.takeException(), isNull);
      }

      await check();
      final grip = find.byKey(const ValueKey('pool-column-grip-song'));
      await Scrollable.ensureVisible(t.element(grip));
      await t.pumpAndSettle();
      await t.drag(grip, const Offset(-45, 0));
      await t.pumpAndSettle();
      await check();
      for (final width in [1280.0, 960.0, 720.0, 420.0]) {
        t.view.physicalSize = Size(width, 1100);
        await t.pumpAndSettle();
        await check();
      }
      expect(find.byTooltip('快速分配电台'), findsOneWidget);
    },
  );
  testWidgets(
    'playlist keeps drag assignment and has the same search hint as the library',
    (t) async {
      await routing.setupPlaylist(t);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('track-quick-assign')), findsNothing);
      final search = t.widget<TextField>(
        find.byKey(const ValueKey('playlist-search')),
      );
      expect(search.decoration!.hintText, '搜索歌曲 / 歌手 / 文件名');
      expect(find.byWidgetPredicate((w) => w is Draggable), findsWidgets);
      expect(t.takeException(), isNull);
    },
  );
}
