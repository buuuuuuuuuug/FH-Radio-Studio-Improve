import 'package:fh_radio_studio/core/waveform_cache.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/layout_options.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/timing_radio_assignments.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/screens/playlist/radio_column.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/editor_shortcuts.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/quick_assign_dialog.dart';
import 'package:fh_radio_studio/widgets/timing_import_dialog.dart';
import 'package:fh_radio_studio/widgets/timing_match_modes.dart';
import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'radio import is atomic, respects capacity, preserves duplicates and syncs scenes',
    () {
      final before = const PlaylistPlan.empty().assign(
        source: 'C:/music/old.wav',
        radioCode: 'R2',
        playlistType: 'FreeRoam',
        slot: 1,
      );
      const rows = [
        {
          'status': 'ready',
          'source': 'C:/music/new.wav',
          'radio_stations': ['R1', 'R2'],
        },
      ];
      expect(
        () => previewTimingRadioAssignments(
          plan: before,
          rows: rows,
          capacities: {'R1': 1, 'R2': 1},
          playlistType: 'FreeRoam',
          splitTypes: false,
        ),
        throwsFormatException,
      );
      expect(before.assignmentsForRadio('R1', 'FreeRoam'), isEmpty);
      final next = previewTimingRadioAssignments(
        plan: before,
        rows: rows,
        capacities: {'R1': 1, 'R2': 2},
        playlistType: 'FreeRoam',
        splitTypes: false,
      );
      expect(next.assignmentsForRadio('R2', 'Event').length, 2);
      final repeated = previewTimingRadioAssignments(
        plan: next,
        rows: rows,
        capacities: {'R1': 1, 'R2': 2},
        playlistType: 'FreeRoam',
        splitTypes: false,
      );
      expect(repeated.encodeForCli(), next.encodeForCli());
      expect(
        () => previewTimingRadioAssignments(
          plan: before,
          rows: rows,
          capacities: {'R1': 1},
          playlistType: 'FreeRoam',
          splitTypes: true,
        ),
        throwsFormatException,
      );
    },
  );
  test('split scene radio import changes only the selected scene', () {
    final plan = previewTimingRadioAssignments(
      plan: const PlaylistPlan.empty(),
      rows: const [
        {
          'status': 'ready',
          'source': 'C:/music/new.wav',
          'radio_stations': ['R1'],
        },
      ],
      capacities: {'R1': 1},
      playlistType: 'Event',
      splitTypes: true,
    );
    expect(plan.assignmentsForRadio('R1', 'FreeRoam'), isEmpty);
    expect(plan.assignmentsForRadio('R1', 'Event').length, 1);
    expect(
      timingCsvTemplateFor(includeRadio: true).split('\n').first,
      'Filename,Radio_station,TD,PD,TL-A,TL-B,PL-A,PL-B',
    );
  });
  test('all confirmed requires actual valid six markers', () {
    TrackTimingConfig config(Map<String, double> values) => TrackTimingConfig(
      source: 'song',
      bpm: 120,
      markersSec: values,
      confirmed: const {'td': true, 'pd': true, 'tl': true, 'pl': true},
      updatedAt: DateTime(2026),
    );
    expect(config({}).allConfirmed, isFalse);
    final valid = <String, double>{
      'TrackDrop': 1,
      'PostDrop': 9,
      'TrackLoopStart': 2,
      'TrackLoopEnd': 7,
      'PostRaceLoopStart': 2,
      'PostRaceLoopEnd': 7,
    };
    expect(config(valid).allConfirmed, isTrue);
    expect(config({...valid, 'TrackLoopEnd': 1}).allConfirmed, isFalse);
    expect(config({...valid, 'PostDrop': double.nan}).allConfirmed, isFalse);
  });
  test(
    'one loop modifier derives all six shortcuts and navigation is last',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final ctl = EditorShortcutController(prefs);
      ctl.setLoopModifier('Meta');
      ctl.save({
        ...ctl.state,
        EditorAction.tenForward: const EditorChord(
          LogicalKeyboardKey.keyJ,
          shift: true,
        ),
      });
      final reload = EditorShortcutController(prefs);
      expect(
        reload.state[EditorAction.loopTenForward]!.label,
        'Win + Shift + J',
      );
      expect(reload.state[EditorAction.loopBeatForward]!.label, 'Win + →');
      expect(
        editorActionOrder.take(editorActionOrder.length - 2),
        isNot(contains(EditorAction.previous)),
      );
      expect(editorActionOrder.sublist(editorActionOrder.length - 2), [
        EditorAction.previous,
        EditorAction.next,
      ]);
      expect(editorActionOrder.where(loopNudgeActions.contains), isEmpty);
      reload.dispose();
      ctl.dispose();
    },
  );
  testWidgets(
    'incomplete radio is highlighted with progress and a readable count',
    (t) async {
      final track = PoolTrack(
        id: 'pending',
        added: '2026-10-15',
        title: 'Pending song',
        artist: 'Test',
        source: 'C:/music/song.wav',
        durationSec: 180,
        bpm: 120,
        key: '',
        configured: false,
        confirmed: 1,
      );
      await t.pumpWidget(
        helpers.app(
          Center(
            child: SizedBox(
              width: 250,
              height: 300,
              child: PlaylistColumn.radio(
                radio: kRadios.first,
                isCustom: true,
                count: 1,
                pendingCount: 1,
                children: [TrackCard.fromPoolTrack(track)],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('⚠ 1 首未完成'), findsOneWidget);
      expect(find.text('未完成 1/4'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'numeric quick assign accepts incomplete song and full station keeps dialog open',
    (t) async {
      t.view.physicalSize = const Size(1200, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      final prefs = await SharedPreferences.getInstance();
      final track = f.container.read(realPoolTracksProvider).first;
      final catalog = PlaylistCatalog(
        origin: PlaylistCatalogOrigin.package,
        sourcePath: 'fixture',
        radios: const [
          RadioStation(
            code: 'R1',
            name: 'Test radio',
            hue: 'lime',
            genre: 'Test',
            slot: 1,
          ),
        ],
        modes: const {'R1': StationMode.builtin},
        freeRoamTracks: const {},
        eventTracks: const {},
      );
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playlistCatalogProvider.overrideWithValue(catalog),
          baselinePlaylistCatalogProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showQuickAssign(context, track),
                child: const Text('Assign'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Assign'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.digit1);
      await t.pumpAndSettle();
      expect(find.byType(QuickAssignDialog), findsNothing);
      expect(
        c
            .read(effectivePlaylistPlanProvider)
            .assignmentsForRadio('R1', 'FreeRoam')
            .length,
        1,
      );
      final pending = c.read(playlistProvider).pool.first;
      expect(pending.configured, isFalse);
      // Replace the one slot with another source so this song genuinely exceeds capacity.
      c
          .read(playlistPlanProvider.notifier)
          .replaceWith(
            const PlaylistPlan.empty().assign(
              source: 'C:/music/occupied.wav',
              radioCode: 'R1',
              playlistType: 'FreeRoam',
              slot: 1,
            ),
          );
      await t.tap(find.text('Assign'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.numpad1);
      await t.pumpAndSettle();
      expect(find.byType(QuickAssignDialog), findsOneWidget);
      expect(find.textContaining('已满或'), findsOneWidget);
      expect(
        c
            .read(effectivePlaylistPlanProvider)
            .assignmentsForRadio('R1', 'FreeRoam')
            .single
            .source,
        'C:/music/occupied.wav',
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'editor assign uses Ctrl D and narrow title actions do not overflow',
    (t) async {
      t.view.physicalSize = const Size(900, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      );
      await t.pumpAndSettle();
      await helpers.keyCombo(t, LogicalKeyboardKey.keyD, ctrl: true);
      expect(find.byType(QuickAssignDialog), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'timing template is inline, optional radio changes it, small dialogs scroll',
    (t) async {
      t.view.physicalSize = const Size(950, 680);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(const TimingImportDialog()),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text(timingCsvTemplate), findsOneWidget);
      await t.tap(find.text('使用 Radio_station 列分配电台'));
      await t.pumpAndSettle();
      expect(
        find.text(timingCsvTemplateFor(includeRadio: true)),
        findsOneWidget,
      );
      expect(find.text('复制 CSV 模板'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  test(
    'incomplete Event assignment is blocked before existing prepared package is replaced',
    () async {
      final f = await fixture.fixture();
      final c = f.container;
      final source = c.read(realPoolTracksProvider).first.source;
      final marker = File('${f.dir.path}/build/current-package/preserved.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('keep');
      final before = marker.readAsStringSync();
      final plan = const PlaylistPlan.empty().assign(
        source: source,
        radioCode: 'R1',
        playlistType: 'Event',
        slot: 1,
        projectDir: f.dir.path,
      );
      final ok = await c.read(studioProvider.notifier).buildPackage(plan: plan);
      expect(ok, isFalse);
      expect(marker.readAsStringSync(), before);
      expect(c.read(studioProvider).log.join('\n'), contains('未完成或未确认'));
    },
  );
  testWidgets(
    'save and assign persists complete nodes before opening the station chooser',
    (t) async {
      t.view.physicalSize = const Size(1400, 1050);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = await fixture.fixture();
      final c = f.container;
      c.read(editorOptionsProvider.notifier).update(manualOnly: true);
      final track = c.read(realPoolTracksProvider).first;
      await t.runAsync(
        () => WaveformCache.write(f.dir.path, track.source, {
          'duration_sec': 180,
          'sample_rate': 48000,
          'waveform': {
            'bins': List.generate(8192, (_) => {'norm_peak': .4}),
          },
        }),
      );
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(
            ReplaceEditorScreen(trackId: track.id, enableAudio: false),
          ),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      final n = c.read(replaceEditorProvider(track.id).notifier);
      n.applyManualPoint(GroupKind.td, 1);
      n.applyManualPoint(GroupKind.pd, 80);
      n.applyManualLoop(GroupKind.tl, 10, 60);
      n.applyManualLoop(GroupKind.pl, 10, 60);
      await t.pumpAndSettle();
      expect(find.text('保存并分配电台'), findsOneWidget);
      await t.tap(find.text('保存并分配电台'));
      await t.pumpAndSettle();
      expect(find.byType(QuickAssignDialog), findsOneWidget);
      expect(
        TrackTimingStore.readAll(
          f.dir.path,
        )[TrackTimingConfig.keyForPath(track.source)]!.allConfirmed,
        isTrue,
      );
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'one row mode snaps the outer board and leaves manual mode free',
    (t) async {
      t.view.physicalSize = const Size(1500, 1050);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await fixture.fixture();
      final prefs = await SharedPreferences.getInstance();
      final catalog = PlaylistCatalog(
        origin: PlaylistCatalogOrigin.package,
        sourcePath: 'fixture',
        radios: kRadios.take(9).toList(),
        modes: const {},
        freeRoamTracks: const {},
        eventTracks: const {},
      );
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playlistCatalogProvider.overrideWithValue(catalog),
        ],
      );
      addTearDown(c.dispose);
      c.read(layoutOptionsProvider.notifier).setRadioColumns(2);
      c
          .read(layoutOptionsProvider.notifier)
          .setHeightMode(RadioHeightMode.oneRow);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(const PlaylistScreen()),
        ),
      );
      await t.pumpAndSettle();
      final board = find.byKey(const ValueKey('playlist-radio-board'));
      final grid = t.widget<GridView>(board);
      final controller = grid.controller!;
      final extent =
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .mainAxisExtent! +
          12;
      controller.jumpTo(extent * .7);
      await t.pump(const Duration(milliseconds: 300));
      expect(controller.offset, closeTo(extent * .7, 1));
      // Continuing to scroll restarts the full idle detection period.
      controller.jumpTo(extent * .75);
      await t.pump(const Duration(milliseconds: 300));
      expect(controller.offset, closeTo(extent * .75, 1));
      await t.pump(const Duration(milliseconds: 170));
      await t.pumpAndSettle();
      expect(controller.offset, closeTo(extent, 1));
      c
          .read(layoutOptionsProvider.notifier)
          .setHeightMode(RadioHeightMode.manual);
      await t.pumpAndSettle();
      controller.jumpTo(120);
      await t.pump(const Duration(milliseconds: 180));
      await t.pumpAndSettle();
      expect(controller.offset, closeTo(120, 1));
      expect(t.takeException(), isNull);
    },
  );
}
