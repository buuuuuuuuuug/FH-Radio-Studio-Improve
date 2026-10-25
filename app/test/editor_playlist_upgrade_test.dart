import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fh_radio_studio/core/waveform_cache.dart';
import 'package:fh_radio_studio/widgets/song_browse_controls.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/song_browse.dart';
import 'package:fh_radio_studio/core/time_input.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/time_group_card.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_painter.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/unsaved_edits.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/time_input_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'pasted common timestamps parse accurately and reject invalid inputs',
    () {
      final samples = <String, double>{
        '83.456': 83.456,
        '1:23.456': 83.456,
        '00:01:23,456': 83.456,
        '１': -1,
        '1分23秒456毫秒': 83.456,
        '1m 23.456s': 83.456,
        '83456ms': 83.456,
        '01：23．456': 83.456,
        '1h 2min 3sec': 3723,
        ' 1 : 23.456 ': 83.456,
      };
      samples.remove('１');
      for (final e in samples.entries) {
        expect(parseTimeInput(e.key), closeTo(e.value, 1e-8), reason: e.key);
      }
      for (final value in ['-1', '1:60', 'a', '1:2:3:4', 'NaN', '']) {
        expect(
          () => parseTimeInput(value),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );

  test(
    'auto sync defaults off, copies edited loop and confirmation, survives reload',
    () async {
      final f = await fixture();
      final c = f.container;
      final provider = replaceEditorProvider('p1');
      final sub = c.listen(provider, (_, _) {});
      addTearDown(sub.close);
      final n = c.read(provider.notifier);
      final originalPl = n.state.pl;
      expect(c.read(editorOptionsProvider).syncPostLoop, isFalse);
      n.editTime(GroupKind.tl, FineTarget.loopStart, 10);
      expect(n.state.pl.start, originalPl.start);
      c
          .read(editorOptionsProvider.notifier)
          .update(syncPostLoop: true, manualOnly: true);
      n.editTime(GroupKind.tl, FineTarget.loopStart, 12.345);
      expect(n.state.pl.start, n.state.tl.start);
      expect(n.state.pl.end, n.state.tl.end);
      expect(n.state.plConfirmed, isFalse);
      n.setConfirmed(GroupKind.tl, true);
      expect(n.state.plConfirmed, isTrue);
      c.invalidate(editorOptionsProvider);
      expect(c.read(editorOptionsProvider).syncPostLoop, isTrue);
      expect(c.read(editorOptionsProvider).manualOnly, isTrue);
      n.setPlayhead(100);
      n.zoomIn();
      expect(
        n.state.zoomEnd - n.state.zoomStart,
        lessThan(n.state.ai.durationSec),
      );
    },
  );

  test(
    'manual mode opens unconfigured real song without AI and saved audio uses no fake waveform',
    () async {
      final f = await fixture();
      final c = f.container;
      c.read(editorOptionsProvider.notifier).update(manualOnly: true);
      final source = p.join(f.dir.path, 'sources', 'song.wav');
      final id = realTrackIdForPath(source);
      final sub = c.listen(replaceEditorProvider(id), (_, _) {});
      addTearDown(sub.close);
      final s = c.read(replaceEditorProvider(id));
      expect(s.analyzing, isFalse);
      expect(s.ai.waveformPeaks, isEmpty);
      expect(s.ai.segments, isEmpty);
      expect(s.td.t, 0);
      expect(s.tl.start, 0);
      expect(s.tl.end, s.ai.durationSec);
    },
  );

  test(
    'reordering preserves other station, persists and reloads without building',
    () async {
      final f = await fixture();
      final c = f.container;
      final sources = [
        'a',
        'b',
        'c',
        'other',
      ].map((v) => p.join(f.dir.path, 'sources', '$v.wav')).toList();
      var plan = const PlaylistPlan.empty();
      for (var i = 0; i < sources.length; i++) {
        File(sources[i]).writeAsBytesSync([0]);
        plan = plan.assign(
          source: sources[i],
          radioCode: i == 3 ? 'R2' : 'R1',
          playlistType: 'FreeRoam',
          slot: i == 3 ? 1 : i + 1,
          projectDir: f.dir.path,
        );
      }
      plan = plan.moveBefore(
        source: sources[2],
        beforeSource: sources[0],
        radioCode: 'R1',
        playlistType: 'FreeRoam',
      );
      expect(plan.assignmentsForRadio('R1', 'FreeRoam').map((a) => a.source), [
        sources[2],
        sources[0],
        sources[1],
      ]);
      expect(
        plan.assignmentsForRadio('R2', 'FreeRoam').single.source,
        sources[3],
      );
      final n = c.read(playlistPlanProvider.notifier);
      n.replaceWith(plan);
      expect(n.dirty, isTrue);
      n.save();
      expect(n.dirty, isFalse);
      c.invalidate(playlistPlanProvider);
      expect(c.read(playlistPlanProvider).encodeForCli(), plan.encodeForCli());
      final reloaded = c.read(playlistPlanProvider.notifier);
      reloaded.replaceWith(const PlaylistPlan.empty());
      reloaded.save();
      c.invalidate(playlistPlanProvider);
      expect(c.read(effectivePlaylistPlanProvider).assignments, isEmpty);
      expect(c.read(playlistPlanProvider.notifier).hasUserPlan, isTrue);
    },
  );

  test(
    'shared browse applies search, station, date and duplicates consistently',
    () {
      PoolTrack track(
        String id,
        String title,
        String artist,
        String? station,
        int date,
      ) => PoolTrack(
        id: id,
        title: title,
        artist: artist,
        source: '$id.wav',
        durationSec: 100,
        bpm: 100,
        key: '',
        configured: true,
        confirmed: 4,
        added: '',
        assignedTo: station,
        modifiedAt: DateTime(2026, 10, date),
      );
      final tracks = [
        track('a', 'Beta', 'Z', 'R2', 10),
        track('b', 'Alpha', 'A', 'R1', 12),
        track('c', 'Alpha', 'A', 'R1', 11),
      ];
      expect(
        browseSongs(
          tracks,
          const SongBrowse(
            search: 'alpha',
            station: 'R1',
            sort: SongSort.modifiedNewest,
          ),
        ).map((t) => t.id),
        ['b', 'c'],
      );
      expect(
        browseSongs(
          tracks,
          const SongBrowse(filter: SongFilter.duplicates),
        ).length,
        2,
      );
      expect(
        browseSongs(
          tracks,
          const SongBrowse(sort: SongSort.artist),
        ).first.artist,
        'A',
      );
      expect(
        tracks[0].copyWith(assignedTo: 'R9').modifiedAt,
        tracks[0].modifiedAt,
      );
    },
  );

  testWidgets(
    'save before leaving commits an unfinished manual refinement draft',
    (tester) async {
      final f = await fixture();
      f.container.read(editorOptionsProvider.notifier).update(manualOnly: true);
      final track = PoolTrack(
        id: 'manual-draft-fixture',
        title: 'Song',
        artist: 'Test',
        source: p.join(f.dir.path, 'sources', 'song.wav'),
        durationSec: 180,
        bpm: 120,
        key: '',
        configured: false,
        confirmed: 0,
        added: '',
        sampleRate: 48000,
        channels: 2,
        samples: 8640000,
      );
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          realPoolTracksProvider.overrideWithValue([track]),
        ],
      );
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: ReplaceEditorScreen(trackId: track.id, enableAudio: false),
            ),
          ),
        ),
      );
      await tester.pump();
      final manual = find.byKey(const ValueKey('editor-manual-refine-td'));
      await Scrollable.ensureVisible(
        tester.element(manual),
        alignment: 0.4,
        duration: Duration.zero,
      );
      await tester.pump();
      await tester.tap(manual);
      await tester.pump(const Duration(milliseconds: 300));
      tester
          .widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform).first)
          .onPlace(37.123, isMove: false);
      await tester.pump();
      final n = c.read(replaceEditorProvider(track.id).notifier);
      expect(n.state.td.t, 0);
      final pending = c.read(unsavedEditsProvider).entries['editor']!;
      expect(pending.dirty(), isTrue);
      await pending.save();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final saved = TrackTimingStore.readAll(f.dir.path).values.single;
      expect(saved.markersSec['TrackDrop'], closeTo(37.123, 1e-8));
      expect(saved.confirmed['td'], isTrue);
      expect(n.state.dirty, isFalse);
      expect(find.byKey(const ValueKey('manual-refine-overlay')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final choice in ['取消返回', '放弃更改', '保存并返回', '保存失败']) {
    testWidgets(
      'unsaved return handles $choice without losing edits on failure',
      (tester) async {
        final edits = UnsavedEdits();
        var dirty = true;
        var saves = 0;
        var discards = 0;
        bool? result;
        edits.entries['editor'] = PendingEdit(
          label: 'Song',
          dirty: () => dirty,
          save: () {
            if (choice == '保存失败') throw const FormatException('Invalid time');
            saves++;
            dirty = false;
          },
          discard: () {
            discards++;
            dirty = false;
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await edits.confirm(context, key: 'editor');
                  },
                  child: const Text('Back'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        expect(find.text('存在未保存的修改'), findsOneWidget);
        await tester.tap(find.text(choice == '保存失败' ? '保存并返回' : choice));
        await tester.pumpAndSettle();
        expect(result, choice == '保存失败' || choice == '取消返回' ? isFalse : isTrue);
        expect(dirty, choice == '保存失败' || choice == '取消返回');
        expect(saves, choice == '保存并返回' ? 1 : 0);
        expect(discards, choice == '放弃更改' ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'window close can cancel, then save all pending playlist and editor changes',
    (tester) async {
      final edits = UnsavedEdits();
      var dirty = true;
      var count = 0;
      bool? result;
      for (final key in ['playlist', 'editor']) {
        edits.entries[key] = PendingEdit(
          label: key,
          dirty: () => dirty,
          save: () {
            count++;
          },
          discard: () {},
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  result = await edits.confirm(ctx, exiting: true);
                },
                child: const Text('Close'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消关闭'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(count, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并关闭'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(count, 2);
    },
  );

  testWidgets(
    'time fields accept paste, unchanged blur preserves precision, invalid input is tracked',
    (tester) async {
      var calls = 0;
      double? value;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: TimeInputField(
              seconds: 19.192873,
              onCommit: (v) {
                calls++;
                value = v;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tapAt(const Offset(10, 300));
      await tester.pump();
      expect(calls, 0);
      await tester.enterText(find.byType(TextField), '00:01:23,456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(value, closeTo(83.456, 1e-8));
      await tester.enterText(find.byType(TextField), 'broken');
      TimeInputValidation.flush();
      await tester.pump();
      expect(TimeInputValidation.invalid, isNotEmpty);
      await tester.enterText(find.byType(TextField), '1分24秒');
      TimeInputValidation.flush();
      await tester.pump();
      expect(value, 84);
      expect(TimeInputValidation.invalid, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmed loop has direct preview without unlocking in manual mode',
    (tester) async {
      var previews = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TimeGroupCard(
                kind: GroupKind.tl,
                candidates: const [
                  LoopCandidate(
                    start: 10,
                    end: 100,
                    score: 1,
                    bars: 40,
                    why: 'saved',
                  ),
                ],
                selectedIdx: 0,
                confirmed: true,
                lowConfidence: false,
                onSelect: (_) {},
                manualCandidate: null,
                manualSelected: false,
                onManualRefine: () {},
                onConfirm: (_) {},
                onCancelConfirm: () {},
                onPreview: (_) {},
                onNudge: (_, _) {},
                bpm: 120,
                manualOnly: true,
                onPreviewCurrent: () {
                  previews++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('试听'));
      await tester.pump();
      expect(previews, 1);
      expect(find.textContaining('候选 (top'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'waveform zoom paints actual selected audio region rather than full waveform',
    (tester) async {
      final rm = buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ).extension<RmTheme>()!;
      final bars = WaveformBars.fromValues([
        for (var i = 0; i < 200; i++) i < 100 ? (i + 1) / 100 : (200 - i) / 100,
      ]);
      Future<List<int>> pixels(double start, double end) async {
        final recorder = ui.PictureRecorder();
        WaveformPainter(
          rm: rm,
          bars: bars,
          beats: const [],
          segments: const [],
          duration: 100,
          markers: const [],
          tlLoop: null,
          plLoop: null,
          playhead: -1,
          windowStart: start,
          windowEnd: end,
        ).paint(
          Canvas(recorder),
          Size(200, WaveformPainter.flagPad + WaveformPainter.barsHeight),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          200,
          (WaveformPainter.flagPad + WaveformPainter.barsHeight).ceil(),
        );
        final data = await image.toByteData();
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      }

      await tester.runAsync(() async {
        expect(await pixels(0, 50), isNot(equals(await pixels(50, 100))));
      });
    },
  );

  test(
    'cached CLI waveform survives disk reload and rejects changed source',
    () async {
      final f = await fixture();
      final source = p.join(f.dir.path, 'sources', 'song.wav');
      final payload = <String, dynamic>{
        'waveform': {
          'bins': [
            {'norm_peak': 0.4},
          ],
        },
      };
      await WaveformCache.write(f.dir.path, source, payload);
      WaveformCache.clearMemory();
      expect(
        (await WaveformCache.read(f.dir.path, source))!['waveform'],
        payload['waveform'],
      );
      File(source).writeAsBytesSync([0, 1, 2]);
      expect(await WaveformCache.read(f.dir.path, source), isNull);
    },
  );

  testWidgets(
    'editor text focus does not swallow cursor keys and commits only complete timestamps',
    (tester) async {
      final f = await fixture();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          realPoolTracksProvider.overrideWithValue([
            PoolTrack(
              id: 'p1',
              title: 'Song',
              artist: 'Test',
              source: p.join(f.dir.path, 'sources', 'song.wav'),
              durationSec: 180,
              bpm: 120,
              key: '',
              configured: false,
              confirmed: 0,
              added: '',
            ),
          ]),
        ],
      );
      addTearDown(c.dispose);
      c.read(editorOptionsProvider.notifier).update(manualOnly: true);
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
            ),
          ),
        ),
      );
      await tester.pump();
      final field = find.descendant(
        of: find.byType(TimeInputField).first,
        matching: find.byType(TextField),
      );
      await Scrollable.ensureVisible(tester.element(field), alignment: 0.4);
      await tester.pump();
      final n = c.read(replaceEditorProvider('p1').notifier);
      n.setConfirmed(GroupKind.td, true);
      n.setPlayhead(80);
      await tester.pump();
      await tester.tap(field);
      await tester.pump();
      expect(TimeInputValidation.focused, isNotEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.selection.start, 0);
      expect(controller.selection.end, controller.text.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(n.state.playhead, 80);
      final before = n.state.td.t;
      await tester.enterText(field, '1:');
      await tester.pump();
      expect(n.state.td.t, before);
      await tester.enterText(field, '0:37.123');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(n.state.td.t, closeTo(37.123, 1e-8));
      expect(n.state.tdConfirmed, isFalse);
      await tester.enterText(field, '0:38.456');
      final config = n.saveToProject();
      expect(config.markersSec['TrackDrop'], closeTo(38.456, 1e-8));
      expect(TimeInputValidation.drafts, isEmpty);
      await tester.pump();
      // Manual-only refinement fills the available width without AI suggestions.
      final manual = find.byKey(const ValueKey('editor-manual-refine-td'));
      await Scrollable.ensureVisible(tester.element(manual), alignment: 0.4);
      await tester.pump();
      await tester.tap(manual);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('manual-refine-ai-panel')),
        findsNothing,
      );
      final manualInput = find.descendant(
        of: find.byKey(const ValueKey('manual-time-point')),
        matching: find.byType(TextField),
      );
      await tester.enterText(manualInput, '0:39.789');
      TimeInputValidation.flush();
      await tester.pump();
      n.saveToProject();
      await tester.pump();
      expect(n.state.td.t, closeTo(39.789, 1e-8));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'browse controls default to filename and do not duplicate playlist search',
    (tester) async {
      var value = const SongBrowse();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                width: 240,
                child: SongBrowseControls(
                  value: value,
                  compact: true,
                  showSearch: false,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('文件名称'), findsOneWidget);
      expect(find.text('分配的电台'), findsNothing);
      await tester.tap(find.text('正序'));
      await tester.pump();
      expect(value.descending, isTrue);
      expect(find.text('倒序'), findsOneWidget);
      final f = await fixture();
      final all = f.container.read(realPoolTracksProvider);
      expect(
        browseSongs(all, value),
        browseSongs(all, const SongBrowse()).reversed.toList(),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<({Directory dir, ProviderContainer container})> fixture() async {
  final dir = Directory.systemTemp.createTempSync('studio_upgrade_');
  FhRadioStudioProject.ensure(dir.path);
  FhRadioStudioProject.writeSettings(dir.path, slmEnabled: false);
  final baseline = File(
    p.join(dir.path, 'backups', 'baseline-current', 'baseline_manifest.json'),
  );
  baseline.parent.createSync(recursive: true);
  baseline.writeAsStringSync(
    '{"kind":"game_baseline","state":"current","files":[]}',
    encoding: utf8,
  );
  final file = File(p.join(dir.path, 'sources', 'song.wav'))
    ..writeAsBytesSync([0]);
  final sourceRef = projectRefForPath(dir.path, file.path)!;
  File(TrackMetadataCache.configPath(dir.path)).writeAsStringSync(
    jsonEncode({
      'schema_version': 2,
      'tracks': [
        for (final ref in [
          sourceRef,
          'fh-project:/sources/a.wav',
          'fh-project:/sources/b.wav',
          'fh-project:/sources/c.wav',
          'fh-project:/sources/other.wav',
        ])
          {
            'track_key': trackKeyForSourceRef(ref),
            'source_ref': ref,
            'artist': 'Test',
            'title': 'Song',
            'duration_sec': 180,
            'sample_rate': 48000,
            'channels': 2,
            'samples': 8640000,
          },
      ],
    }),
    encoding: utf8,
  );
  SharedPreferences.setMockInitialValues({
    'rm.studio.projectDir': dir.path,
    'rm.studio.repoRoot': p.dirname(p.current),
  });
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
    ],
  );
  addTearDown(() {
    c.dispose();
    dir.deleteSync(recursive: true);
  });
  return (dir: dir, container: c);
}
