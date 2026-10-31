import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_editor.dart';
import 'package:fh_radio_studio/screens/stingers.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/time_input_field.dart';
import 'voice_clip_editor_test.dart' as voice;
import 'stinger_staged_edit_test.dart' as stinger;
import 'editor_playlist_upgrade_test.dart' as song;
import 'studio_v18_workflow_test.dart' as state;
import 'studio_v21_workflow_test.dart' as helpers;

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _Player extends Fake implements Player {
  @override
  PlayerState get state => const PlayerState();
  @override
  PlayerStream get stream => _Streams();
  @override
  Future<void> pause() async {}
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'time labels share the exact grid coordinate at fractional durations and zoom',
    (t) async {
      t.view.physicalSize = const Size(1100, 500);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      for (final start in [0.0, .3]) {
        final end = start == 0 ? 2.42 : 1.3;
        await t.pumpWidget(
          helpers.app(
            Center(
              child: SizedBox(
                width: 900,
                child: ManualFocusWaveform(
                  bars: WaveformBars.fromValues(List.filled(100, .5)),
                  beats: const [],
                  segments: const [],
                  duration: 2.42,
                  accent: Colors.green,
                  handles: const [],
                  free: true,
                  locked: false,
                  windowStart: start,
                  windowEnd: end,
                  timeGrid: true,
                  onPlace: (_, {required isMove}) {},
                ),
              ),
            ),
          ),
        );
        final wave = t.getRect(find.byType(ManualFocusWaveform));
        for (final time in start == 0 ? [.5, 1.0, 1.5, 2.0] : [.5, 1.0]) {
          final label = find.byKey(
            ValueKey('wave-time-${time.toStringAsFixed(6)}'),
          );
          expect(
            t.getCenter(label).dx,
            closeTo(
              wave.left + (time - start) / (end - start) * wave.width,
              .1,
            ),
          );
        }
      }
      expect(WaveformTimeGrid(2.42, 900).minorStep, closeTo(.1, .00001));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'voice action controls align at a common height and leave no empty status strip',
    (t) async {
      await voice.open(t, 1100);
      final transport = find.byKey(const ValueKey('material-transport'));
      final actions = find.byKey(const ValueKey('material-edit-panel'));
      final volume = find.byKey(const ValueKey('material-volume'));
      for (final key in [
        'material-insert-silence',
        'material-silence-selection',
        'material-delete-selection',
        'editor-history-undo',
        'editor-history-redo',
      ]) {
        expect(t.getSize(find.byKey(ValueKey(key))).height, 32);
      }
      expect(t.getRect(transport).left, t.getRect(actions).left);
      expect(t.getRect(transport).right, t.getRect(actions).right);
      expect(t.getRect(volume).left, greaterThan(t.getRect(actions).right));
      expect(find.text('静音时长'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'stinger pool retains A B and next-song inputs and right click places a point',
    (t) async {
      t.view.physicalSize = const Size(1280, 950);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = await state.fixture();
      addTearDown(c.dispose);
      final material = <String, dynamic>{
        'id': 'a',
        'name': 'Voice',
        'duration': 8.0,
        'edit': {
          'asset_id': 'a',
          'start': 0.0,
          'end': 8.0,
          'gain_db': 0.0,
          'next_track': 6.0,
        },
        'source_preview': {
          'path': 'source.wav',
          'duration': 8.0,
          'bins': List.filled(100, .5),
        },
      };
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(
            StingerEditor(
              asset: material,
              assets: [material],
              songs: const [],
              player: _Player(),
              preferredWidth: 1200,
              usedCount: 0,
              play: (_, {start, end, gain = 0}) async {},
              call: (_, input) async => {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (final name in ['start', 'end', 'next']) {
        expect(find.byKey(ValueKey('stinger-time-$name')), findsOneWidget);
      }
      final wave = find.byKey(const ValueKey('stinger-editor-waveform'));
      final rect = t.getRect(wave);
      double next() => t
          .widget<TimeInputField>(
            find.byKey(const ValueKey('stinger-time-next')),
          )
          .seconds;
      await t.tapAt(Offset(rect.left + rect.width * .6, rect.center.dy));
      await t.pumpAndSettle();
      expect(next(), 6);
      await t.tapAt(
        Offset(rect.left + rect.width * .6, rect.center.dy),
        buttons: kSecondaryMouseButton,
      );
      await t.pumpAndSettle();
      expect(next(), closeTo(4.8, .02));
      expect(find.byKey(const ValueKey('stinger-editor-assign')), findsNothing);
      expect(
        t.getCenter(find.byKey(const ValueKey('editor-history-redo'))).dx,
        lessThan(
          t.getCenter(find.byKey(const ValueKey('stinger-use-playhead'))).dx,
        ),
      );
      for (final size in [const Size(1266, 682), const Size(1024, 720)]) {
        t.view.physicalSize = size;
        await t.pumpAndSettle();
        expect(
          t.getRect(find.byKey(const ValueKey('stinger-time-next'))).bottom,
          lessThan(
            t.getRect(find.byKey(const ValueKey('stinger-editor-footer'))).top,
          ),
        );
      }
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'cached stinger board and import control appear on the first frame',
    (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = await state.fixture();
      addTearDown(c.dispose);
      final studio = c.read(studioProvider);
      final data = stinger.catalog(studio.targetLang);
      c.read(stingerMemoryCacheProvider.notifier).state = {
        '${studio.projectDir}|${studio.gameDir}|${studio.targetLang}|false':
            data,
      };
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: ProviderScope(
            overrides: [automaticFeatureToursProvider.overrideWithValue(false)],
            child: helpers.app(const StingersScreen()),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('stinger-pool')), findsOneWidget);
      expect(find.text('正在准备台呼缓存'), findsNothing);
      final import = find.byKey(const ValueKey('stinger-import'));
      expect(
        t.getRect(import).right,
        lessThanOrEqualTo(
          t.getRect(find.byKey(const ValueKey('stinger-pool'))).right,
        ),
      );
      expect(
        t.getCenter(import).dx,
        greaterThan(t.getCenter(find.text('池子')).dx),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('song precision undo and redo work and new edits clear redo', (
    t,
  ) async {
    t.view.physicalSize = const Size(1700, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = await song.fixture();
    addTearDown(f.container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: helpers.app(
          const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
        ),
      ),
    );
    await t.pumpAndSettle();
    final open = find.byKey(const ValueKey('editor-manual-refine-tl'));
    await Scrollable.ensureVisible(t.element(open));
    await t.pumpAndSettle();
    await t.tap(open);
    await t.pumpAndSettle();
    List<double> times() => t
        .widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform))
        .handles
        .map((h) => h.t)
        .toList();
    final initial = times();
    final nudge = find.widgetWithText(RmButton, '+10').first;
    await t.tap(nudge);
    await t.pumpAndSettle();
    final edited = times();
    expect(edited, isNot(initial));
    final undo = find.byKey(const ValueKey('editor-history-undo')),
        redo = find.byKey(const ValueKey('editor-history-redo'));
    await t.tap(undo);
    await t.pumpAndSettle();
    expect(times(), initial);
    await t.tap(redo);
    await t.pumpAndSettle();
    expect(times(), edited);
    await t.tap(undo);
    await t.pumpAndSettle();
    await t.tap(nudge);
    await t.pumpAndSettle();
    expect(t.widget<RmButton>(redo).onPressed, isNull);
    expect(
      t.getRect(redo).right,
      lessThan(
        t.getRect(find.byKey(const ValueKey('manual-use-playhead'))).left,
      ),
    );
    expect(t.takeException(), isNull);
  });
}
