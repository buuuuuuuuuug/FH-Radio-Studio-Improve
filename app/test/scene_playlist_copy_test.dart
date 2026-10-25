import 'dart:io';

import 'package:fh_radio_studio/core/playlist_capacity.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/screens/playlist/radio_column.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_capacity.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'split_playlist_state_test.dart' as fixtures;

class _Controller extends StudioController {
  _Controller(super.prefs) {
    state = state.copyWith(
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: 'baseline.json',
        pendingBaselineManifestPath: null,
        packageManifestPath: null,
        lastAppliedPackageManifestPath: null,
      ),
    );
  }

  void setBusy(bool value) => state = state.copyWith(busy: value);
}

Future<ProviderContainer> _container(
  Directory dir,
  List<PoolTrack> tracks, {
  int freeCapacity = 22,
  int eventCapacity = 22,
}) async {
  SharedPreferences.setMockInitialValues({'rm.studio.projectDir': dir.path});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      studioProvider.overrideWith((ref) => _Controller(prefs)),
      realPoolTracksProvider.overrideWithValue(tracks),
      playlistCapacityPolicyProvider.overrideWithValue(
        PlaylistCapacityPolicy({
          'R9': {'FreeRoam': freeCapacity, 'Event': eventCapacity},
        }),
      ),
      playlistCatalogProvider.overrideWithValue(
        const PlaylistCatalog(
          origin: PlaylistCatalogOrigin.package,
          sourcePath: null,
          radios: [],
          modes: {},
          freeRoamTracks: {},
          eventTracks: {},
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _sources(PlaylistPlan plan, String radio, String type) => [
  for (final a in plan.assignmentsForRadio(radio, type)) a.source,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  for (final from in ['FreeRoam', 'Event']) {
    test(
      'copy $from is ordered, station scoped and one undoable edit',
      () async {
        final dir = fixtures.project();
        FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
        final tracks = fixtures.tracksFor(dir);
        final to = from == 'Event' ? 'FreeRoam' : 'Event';
        final original = fixtures
            .splitPlan(dir, tracks)
            .assign(
              source: tracks[0].source,
              radioCode: 'R1',
              playlistType: to,
              slot: 1,
              projectDir: dir.path,
            )
            .setSplitMode(true);
        final c = await _container(dir, tracks);
        final songs = c.read(playlistProvider.notifier);
        final history = c.read(playlistPlanProvider.notifier);
        history.replaceWith(original);
        history.save();
        expect(
          songs.copyScenePlaylist('R9', fromType: from, toType: to),
          isTrue,
          reason: songs.lastEditBlockedReason,
        );
        final copied = c.read(playlistPlanProvider);
        expect(_sources(copied, 'R9', to), _sources(original, 'R9', from));
        expect(_sources(copied, 'R9', from), _sources(original, 'R9', from));
        expect(_sources(copied, 'R1', to), _sources(original, 'R1', to));
        expect(
          copied.assignmentsForRadio('R9', to).map((a) => a.slot),
          List.generate(22, (i) => i + 1),
        );
        expect(copied.sourcesForRadio('R9'), hasLength(22));
        expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
        expect(history.dirty, isTrue);
        history.undo();
        expect(
          c.read(playlistPlanProvider).encodeForStorage(),
          original.encodeForStorage(),
        );
        expect(history.dirty, isFalse);
        history.redo();
        expect(
          c.read(playlistPlanProvider).encodeForStorage(),
          copied.encodeForStorage(),
        );
        history.save();
        c.invalidate(playlistPlanProvider);
        c.invalidate(playlistProvider);
        expect(
          _sources(c.read(playlistPlanProvider), 'R9', to),
          _sources(original, 'R9', from),
        );
        expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      },
    );
  }

  test(
    'copying a legacy inferred split layout keeps split editing enabled',
    () async {
      final dir = fixtures.project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = fixtures.tracksFor(dir);
      final legacy = fixtures.splitPlan(dir, tracks);
      expect(legacy.splitPlaylistTypes, isNull);
      PlaylistPlanStore.write(dir.path, legacy);
      final c = await _container(dir, tracks);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      final songs = c.read(playlistProvider.notifier);
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isTrue,
        reason: songs.lastEditBlockedReason,
      );
      expect(c.read(playlistPlanProvider).hasSplitPlaylistDifferences, isFalse);
      expect(c.read(playlistPlanProvider).splitPlaylistTypes, isTrue);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      c.read(playlistPlanProvider.notifier).save();
      c.invalidate(playlistPlanProvider);
      c.invalidate(playlistProvider);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
    },
  );

  test(
    'applying the same scene playlist leaves dirty state and undo intact',
    () async {
      final dir = fixtures.project();
      final tracks = fixtures.tracksFor(dir);
      final original = const PlaylistPlan.empty()
          .assign(
            source: tracks[0].source,
            radioCode: 'R9',
            playlistType: 'Event',
            slot: 1,
            projectDir: dir.path,
          )
          .assign(
            source: tracks[1].source,
            radioCode: 'R9',
            playlistType: 'FreeRoam',
            slot: 1,
            projectDir: dir.path,
          )
          .setSplitMode(true);
      final c = await _container(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      final history = c.read(playlistPlanProvider.notifier);
      history.replaceWith(original);
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isTrue,
        reason: songs.lastEditBlockedReason,
      );
      history.save();
      final identical = c.read(playlistPlanProvider).encodeForStorage();
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isTrue,
        reason: songs.lastEditBlockedReason,
      );
      expect(c.read(playlistPlanProvider).encodeForStorage(), identical);
      expect(history.dirty, isFalse);
      history.undo();
      expect(
        c.read(playlistPlanProvider).encodeForStorage(),
        original.encodeForStorage(),
      );
    },
  );

  test('missing source files cannot be copied into the other scene', () async {
    final dir = fixtures.project();
    final tracks = fixtures.tracksFor(dir);
    final c = await _container(dir, tracks);
    final history = c.read(playlistPlanProvider.notifier);
    history.replaceWith(
      const PlaylistPlan.empty()
          .assign(
            source: tracks[0].source,
            radioCode: 'R9',
            playlistType: 'Event',
            slot: 1,
            projectDir: dir.path,
          )
          .setSplitMode(true),
    );
    history.save();
    File(tracks[0].source).deleteSync();
    final before = c.read(playlistPlanProvider).encodeForStorage();
    final songs = c.read(playlistProvider.notifier);
    expect(
      songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
      isFalse,
    );
    expect(songs.lastEditBlockedReason, contains('找不到的歌曲文件'));
    expect(c.read(playlistPlanProvider).encodeForStorage(), before);
    expect(history.dirty, isFalse);
  });

  test('copy preserves local snapshot and clears only target builtin flag', () {
    var base = const PlaylistPlan.empty()
        .restoreBuiltin(radioCode: 'R9', playlistType: 'FreeRoam')
        .restoreBuiltin(radioCode: 'R1', playlistType: 'Event')
        .assign(
          source: 'C:/a.wav',
          radioCode: 'R9',
          playlistType: 'Event',
          slot: 4,
        );
    final snapshot = base;
    base = PlaylistPlan(
      assignments: base.assignments,
      builtinTargets: base.builtinTargets,
      splitPlaylistTypes: true,
      splitSnapshot: snapshot,
    );
    final copied = base.copyScenePlaylist(
      radioCode: 'r9',
      fromType: 'Event',
      toType: 'FreeRoam',
    );
    expect(copied.splitPlaylistTypes, isTrue);
    expect(copied.splitSnapshot, same(snapshot));
    expect(copied.hasBuiltinOverride('R9', 'FreeRoam'), isFalse);
    expect(copied.hasBuiltinOverride('R1', 'Event'), isTrue);
    expect(copied.assignmentsForRadio('R9', 'Event').single.slot, 4);
    expect(copied.assignmentsForRadio('R9', 'FreeRoam').single.slot, 1);
  });

  test(
    'capacity failure leaves plan, dirty state and history untouched',
    () async {
      final dir = fixtures.project();
      final tracks = fixtures.tracksFor(dir);
      final original = const PlaylistPlan.empty()
          .assign(
            source: tracks[0].source,
            radioCode: 'R9',
            playlistType: 'Event',
            slot: 1,
            projectDir: dir.path,
          )
          .assign(
            source: tracks[1].source,
            radioCode: 'R9',
            playlistType: 'Event',
            slot: 2,
            projectDir: dir.path,
          )
          .assign(
            source: tracks[0].source,
            radioCode: 'R9',
            playlistType: 'FreeRoam',
            slot: 1,
            projectDir: dir.path,
          )
          .setSplitMode(true);
      final c = await _container(
        dir,
        tracks,
        freeCapacity: 1,
        eventCapacity: 2,
      );
      final history = c.read(playlistPlanProvider.notifier);
      history.replaceWith(original);
      history.save();
      final songs = c.read(playlistProvider.notifier);
      final undoBefore = history.canUndo;
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isFalse,
      );
      expect(songs.lastEditBlockedReason, contains('超出容量'));
      expect(
        c.read(playlistPlanProvider).encodeForStorage(),
        original.encodeForStorage(),
      );
      expect(history.dirty, isFalse);
      expect(history.canUndo, undoBefore);
      expect(history.canRedo, isFalse);
    },
  );

  test(
    'locked, disabled, same scene and builtin or empty source cannot copy',
    () async {
      final dir = fixtures.project();
      final tracks = fixtures.tracksFor(dir);
      final c = await _container(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isFalse,
      );
      expect(songs.lastEditBlockedReason, contains('启用分场景编辑'));
      songs.setSplitPlaylistTypes(true);
      final history = c.read(playlistPlanProvider.notifier);
      final empty = c.read(playlistPlanProvider).encodeForStorage();
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'Event'),
        isFalse,
      );
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isFalse,
      );
      expect(songs.lastEditBlockedReason, contains('不支持一边原版、一边自建'));
      expect(c.read(playlistPlanProvider).encodeForStorage(), empty);
      history.replaceWith(
        const PlaylistPlan.empty()
            .assign(
              source: tracks[0].source,
              radioCode: 'R9',
              playlistType: 'FreeRoam',
              slot: 1,
              projectDir: dir.path,
            )
            .restoreBuiltin(radioCode: 'R9', playlistType: 'Event')
            .setSplitMode(true),
      );
      final before = c.read(playlistPlanProvider).encodeForStorage();
      expect(
        songs.copyScenePlaylist('R9', fromType: 'Event', toType: 'FreeRoam'),
        isFalse,
      );
      expect(c.read(playlistPlanProvider).encodeForStorage(), before);
      (c.read(studioProvider.notifier) as _Controller).setBusy(true);
      expect(
        songs.copyScenePlaylist('R9', fromType: 'FreeRoam', toType: 'Event'),
        isFalse,
      );
      expect(songs.lastEditBlockedReason, contains('正在执行'));
      expect(c.read(playlistPlanProvider).encodeForStorage(), before);
    },
  );

  testWidgets('scene copy action replaces restore and fits a narrow station', (
    tester,
  ) async {
    var copies = 0;
    var restores = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 220,
            height: 400,
            child: PlaylistColumn.radio(
              radio: kRadios.first,
              isCustom: true,
              count: 1,
              onRestoreBuiltin: () => restores++,
              headerActionLabel: '使用比赛歌单',
              headerActionTooltip: '将比赛歌单复制到漫游。不支持一边原版、一边自建。',
              onHeaderAction: () => copies++,
              children: const [Text('Song')],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('恢复当前列表为 builtin'), findsNothing);
    await tester.tap(find.byTooltip('使用比赛歌单'));
    expect(copies, 1);
    expect(restores, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy action stays visible and disabled without a source list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 220,
            height: 400,
            child: PlaylistColumn.radioBuilder(
              radio: kRadios.first,
              isCustom: false,
              count: 0,
              itemCount: 0,
              itemBuilder: (_, _) => const SizedBox.shrink(),
              headerActionLabel: '使用漫游歌单',
              headerActionTooltip: '另一场景没有自建歌单。不支持一边原版、一边自建。',
            ),
          ),
        ),
      ),
    );
    final button = tester.widget<RmButton>(find.byType(RmButton));
    expect(button.tooltip, '使用漫游歌单');
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
