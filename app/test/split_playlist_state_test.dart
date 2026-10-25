import 'dart:convert';
import 'dart:io';

import 'package:fh_radio_studio/core/package_manifest.dart';
import 'package:fh_radio_studio/core/playlist_capacity.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_capacity.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/widgets/split_playlist_setting.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Directory project() {
  final dir = Directory.systemTemp.createTempSync('split-playlist-');
  FhRadioStudioProject.ensure(dir.path);
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

List<PoolTrack> tracksFor(Directory dir) {
  final tracks = [
    for (var i = 0; i < 44; i++)
      PoolTrack(
        id: 'song-$i',
        source: File(p.join(dir.path, 'sources', '$i.wav')).absolute.path,
        title: 'Song $i',
        artist: 'Test',
        durationSec: 180,
        bpm: 120,
        key: '',
        configured: true,
        confirmed: 4,
        added: '',
      ),
  ];
  for (final track in tracks) {
    File(track.source).writeAsBytesSync(const [0]);
  }
  File(TrackMetadataCache.configPath(dir.path)).writeAsStringSync(
    jsonEncode({
      'schema_version': 2,
      'tracks': [
        for (final track in tracks)
          {
            'track_key': trackKeyForProjectPath(dir.path, track.source),
            'source_ref': projectRefForPath(dir.path, track.source),
            'title': track.title,
            'artist': track.artist,
          },
      ],
    }),
    encoding: utf8,
  );
  return tracks;
}

PlaylistPlan splitPlan(Directory dir, List<PoolTrack> tracks) {
  var plan = const PlaylistPlan.empty();
  for (var i = 0; i < tracks.length; i++) {
    plan = plan.assign(
      source: tracks[i].source,
      radioCode: 'R9',
      playlistType: i < 22 ? 'FreeRoam' : 'Event',
      slot: i % 22 + 1,
      projectDir: dir.path,
    );
  }
  return plan;
}

Future<ProviderContainer> containerFor(
  Directory dir,
  List<PoolTrack> tracks,
) async {
  SharedPreferences.setMockInitialValues({'rm.studio.projectDir': dir.path});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      studioProvider.overrideWith((ref) => _EditableController(prefs)),
      realPoolTracksProvider.overrideWithValue(tracks),
      playlistCapacityPolicyProvider.overrideWithValue(
        PlaylistCapacityPolicy({
          'R9': {'FreeRoam': 22, 'Event': 22},
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

class _EditableController extends StudioController {
  _EditableController(super.prefs) {
    state = state.copyWith(
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: 'baseline.json',
        pendingBaselineManifestPath: null,
        packageManifestPath: null,
        lastAppliedPackageManifestPath: null,
      ),
    );
  }

  void switchProject(Directory dir) {
    state = state.copyWith(projectDir: dir.path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('split requires expansion and does not silently enable it', (
    tester,
  ) async {
    final dir = project();
    final tracks = tracksFor(dir);
    final c = await containerFor(dir, tracks);
    final before = c.read(effectivePlaylistPlanProvider).encodeForStorage();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: SplitPlaylistSetting()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('split-playlist-setting')));
    await tester.pumpAndSettle();
    expect(find.text('请先开启电台扩容'), findsOneWidget);
    expect(c.read(editorOptionsProvider).expansionEnabled, isFalse);
    expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
    expect(c.read(effectivePlaylistPlanProvider).encodeForStorage(), before);
  });

  test('expansion cannot be disabled until split editing is closed', () async {
    final dir = project();
    FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
    final tracks = tracksFor(dir).take(1).toList();
    final c = await containerFor(dir, tracks);
    final songs = c.read(playlistProvider.notifier);
    songs.setSplitPlaylistTypes(true);
    expect(
      c.read(editorOptionsProvider.notifier).update(expansionEnabled: false),
      isFalse,
    );
    expect(c.read(editorOptionsProvider).expansionEnabled, isTrue);
    songs.setSplitPlaylistTypes(false);
    expect(
      c.read(editorOptionsProvider.notifier).update(expansionEnabled: false),
      isTrue,
    );
  });

  test(
    'saved disjoint 22-song scenes remain split after restart and reorder',
    () async {
      final dir = project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = tracksFor(dir);
      final original = splitPlan(dir, tracks);
      PlaylistPlanStore.write(dir.path, original);
      final c = await containerFor(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      final freeBefore = original
          .assignmentsForRadio('R9', 'FreeRoam')
          .map((a) => a.source)
          .toList();
      songs.reorder(tracks.last.source, tracks[22].source, 'R9', 'Event');
      final reordered = c.read(playlistPlanProvider);
      expect(
        reordered.assignmentsForRadio('R9', 'FreeRoam').map((a) => a.source),
        freeBefore,
      );
      expect(
        reordered.assignmentsForRadio('R9', 'Event').first.source,
        tracks.last.source,
      );
      expect(reordered.sourcesForRadio('R9'), hasLength(44));
      c.read(playlistPlanProvider.notifier).save();
      c.invalidate(playlistProvider);
      c.invalidate(playlistPlanProvider);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        reordered.encodeForCli(),
      );
    },
  );

  test(
    'manual split selection persists and does not leak to another project',
    () async {
      final dir = project();
      final other = project();
      final c = await containerFor(dir, tracksFor(dir));
      c.read(playlistProvider.notifier).setSplitPlaylistTypes(true);
      c.read(playlistPlanProvider.notifier).save();
      c.invalidate(playlistProvider);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      final studio = c.read(studioProvider.notifier) as _EditableController;
      studio.switchProject(other);
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      studio.switchProject(dir);
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
    },
  );

  test(
    'receiving a reconstructed split draft protects the other scene on edit',
    () async {
      final dir = project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = tracksFor(dir);
      final c = await containerFor(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      c.read(playlistPlanProvider.notifier).replaceWith(splitPlan(dir, tracks));
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      songs.unassign(tracks[0].id, radioCode: 'R9', playlistType: 'FreeRoam');
      final plan = c.read(playlistPlanProvider);
      expect(plan.assignmentsForRadio('R9', 'FreeRoam'), hasLength(21));
      expect(plan.assignmentsForRadio('R9', 'Event'), hasLength(22));
    },
  );

  test(
    'unified edits preserve frozen scenes through save restart undo and redo',
    () async {
      final dir = project();
      FhRadioStudioProject.writeSettings(
        dir.path,
        expansionEnabled: true,
        splitPlaylistTypes: true,
      );
      final tracks = tracksFor(dir);
      final original = splitPlan(dir, tracks);
      PlaylistPlanStore.write(dir.path, original);
      final c = await containerFor(dir, tracks);
      var songs = c.read(playlistProvider.notifier);
      var history = c.read(playlistPlanProvider.notifier);
      songs.setSplitPlaylistTypes(false, keepType: 'Event');
      final frozen = c.read(playlistPlanProvider).splitSnapshot!.encodeForCli();
      expect(frozen, original.encodeForCli());
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      songs.reorder(tracks.last.source, tracks[22].source, 'R9', 'Event');
      songs.unassign(tracks[23].id, radioCode: 'R9', playlistType: 'Event');
      final unified = c.read(playlistPlanProvider);
      expect(unified.hasSplitPlaylistDifferences, isFalse);
      expect(unified.sourcesForRadio('R9'), hasLength(21));
      expect(unified.splitSnapshot!.encodeForCli(), frozen);
      expect(unified.encodeForCli(), isNot(contains('scene_editing')));
      expect(unified.encodeForStorage(), contains('scene_editing'));
      history.save();
      c.invalidate(playlistProvider);
      c.invalidate(playlistPlanProvider);
      songs = c.read(playlistProvider.notifier);
      history = c.read(playlistPlanProvider.notifier);
      // The old project setting must not override the locally saved off mode.
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(
        c.read(playlistPlanProvider).splitSnapshot!.encodeForCli(),
        frozen,
      );
      songs.setSplitPlaylistTypes(true);
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        original.encodeForCli(),
      );
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      expect(history.dirty, isTrue);
      history.undo();
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(
        c.read(playlistPlanProvider).encodeForStorage(),
        unified.encodeForStorage(),
      );
      history.redo();
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        original.encodeForCli(),
      );
      history.discard();
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(
        c.read(playlistPlanProvider).encodeForStorage(),
        unified.encodeForStorage(),
      );
      final other = project();
      final studio = c.read(studioProvider.notifier) as _EditableController;
      studio.switchProject(other);
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(c.read(playlistPlanProvider).splitSnapshot, isNull);
      studio.switchProject(dir);
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(
        c.read(playlistPlanProvider).encodeForStorage(),
        unified.encodeForStorage(),
      );
    },
  );

  test(
    'scene toggle with identical active lists still records local history',
    () async {
      final dir = project();
      final tracks = tracksFor(dir);
      final c = await containerFor(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      final history = c.read(playlistPlanProvider.notifier);
      songs.setSplitPlaylistTypes(true);
      final cli = c.read(playlistPlanProvider).encodeForCli();
      songs.setSplitPlaylistTypes(false);
      expect(c.read(playlistPlanProvider).encodeForCli(), cli);
      expect(history.canUndo, isTrue);
      history.undo();
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      history.redo();
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
    },
  );

  test('restoring split scenes beyond disabled expansion is atomic', () async {
    final dir = project();
    FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
    final tracks = tracksFor(dir);
    final original = splitPlan(dir, tracks);
    PlaylistPlanStore.write(dir.path, original);
    final c = await containerFor(dir, tracks);
    final songs = c.read(playlistProvider.notifier);
    songs.setSplitPlaylistTypes(false, keepType: 'Event');
    final before = c.read(playlistPlanProvider).encodeForStorage();
    final options = c.read(editorOptionsProvider.notifier);
    expect(options.update(expansionEnabled: false), isTrue);
    expect(
      () => songs.setSplitPlaylistTypes(true),
      throwsA(isA<PlaylistCapacityException>()),
    );
    expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
    expect(c.read(playlistPlanProvider).sourcesForRadio('R9'), hasLength(22));
    expect(
      jsonDecode(c.read(playlistPlanProvider).encodeForCli())['assignments'],
      hasLength(44),
    );
    expect(
      c.read(playlistPlanProvider).splitSnapshot!.sourcesForRadio('R9'),
      hasLength(44),
    );
    expect(c.read(playlistPlanProvider).encodeForStorage(), before);
  });

  testWidgets(
    'playlist button offers unified choice then restores both scenes',
    (tester) async {
      final dir = project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = tracksFor(dir);
      final original = splitPlan(dir, tracks);
      PlaylistPlanStore.write(dir.path, original);
      final c = await containerFor(dir, tracks);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(child: SplitPlaylistSetting()),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('split-playlist-setting')));
      await tester.pumpAndSettle();
      expect(find.text('关闭后统一使用哪张列表？'), findsOneWidget);
      await tester.tap(find.text('统一使用比赛'));
      await tester.pumpAndSettle();
      expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
      expect(
        c.read(playlistPlanProvider).splitSnapshot!.encodeForCli(),
        original.encodeForCli(),
      );
      await tester.tap(find.byKey(const ValueKey('split-playlist-setting')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('split-playlist-enable-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('不推荐'), findsNothing);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        original.encodeForCli(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'deleted files are removed from hidden scenes and cannot return after reload',
    () async {
      final dir = project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = tracksFor(dir);
      PlaylistPlanStore.write(dir.path, splitPlan(dir, tracks));
      final c = await containerFor(dir, tracks);
      var songs = c.read(playlistProvider.notifier);
      var history = c.read(playlistPlanProvider.notifier);
      songs.setSplitPlaylistTypes(false, keepType: 'Event');
      history.save();
      File(tracks.first.source).deleteSync();
      // Simulate deletion outside the running app: loading the frozen snapshot
      // must filter the missing source even without removeDeletedSources().
      c.invalidate(playlistProvider);
      c.invalidate(playlistPlanProvider);
      songs = c.read(playlistProvider.notifier);
      history = c.read(playlistPlanProvider.notifier);
      expect(
        c.read(playlistPlanProvider).splitSnapshot!.sourcesForRadio('R9'),
        hasLength(43),
      );
      history.removeDeletedSources([tracks[1].source]);
      expect(
        c.read(playlistPlanProvider).splitSnapshot!.sourcesForRadio('R9'),
        hasLength(42),
      );
      songs.setSplitPlaylistTypes(true);
      final restored = c.read(playlistPlanProvider);
      expect(restored.assignmentsForRadio('R9', 'FreeRoam'), hasLength(20));
      expect(restored.assignmentsForRadio('R9', 'Event'), hasLength(22));
      expect(
        restored.assignmentsForRadio('R9', 'FreeRoam').map((a) => a.slot),
        List.generate(20, (i) => i + 1),
      );
    },
  );

  for (final selectedMode in [PlaylistMode.freeroam, PlaylistMode.event]) {
    test(
      'copying split game layout stays unified with frozen scenes: $selectedMode',
      () async {
        final dir = project();
        FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
        final tracks = tracksFor(dir);
        final original = splitPlan(dir, tracks);
        PlaylistPlanStore.write(dir.path, original);
        final c = await containerFor(dir, tracks);
        final songs = c.read(playlistProvider.notifier);
        final history = c.read(playlistPlanProvider.notifier);
        songs.setSplitPlaylistTypes(false);
        songs.setMode(selectedMode);
        final before = c.read(playlistPlanProvider).encodeForStorage();
        final catalog = PlaylistCatalog(
          view: PlaylistCatalogView.game,
          origin: PlaylistCatalogOrigin.game,
          sourcePath: 'game-radio-info.xml',
          radios: const [
            RadioStation(
              code: 'R9',
              name: 'Horizon Opus',
              hue: 'lime',
              genre: '',
              slot: 22,
            ),
          ],
          modes: const {'R9': StationMode.custom},
          freeRoamTracks: const {
            'R9': [
              TrackRef(
                id: 'fr',
                title: 'FR',
                artist: 'Test',
                durationSec: 180,
                soundName: 'FR',
              ),
            ],
          },
          eventTracks: const {
            'R9': [
              TrackRef(
                id: 'ev',
                title: 'EV',
                artist: 'Test',
                durationSec: 180,
                soundName: 'EV',
              ),
            ],
          },
          sourceBySoundName: {'FR': tracks[2].source, 'EV': tracks[24].source},
        );
        expect(songs.copyGameLayout(catalog), 2);
        final copied = c.read(playlistPlanProvider);
        final selected =
            tracks[selectedMode == PlaylistMode.event ? 24 : 2].source;
        expect(c.read(playlistProvider).splitPlaylistTypes, isFalse);
        expect(copied.hasSplitPlaylistDifferences, isFalse);
        for (final type in ['FreeRoam', 'Event']) {
          expect(
            copied.assignmentsForRadio('R9', type).single.source,
            selected,
          );
        }
        expect(copied.splitSnapshot!.encodeForCli(), original.encodeForCli());
        history.undo();
        expect(c.read(playlistPlanProvider).encodeForStorage(), before);
        history.redo();
        expect(
          c.read(playlistPlanProvider).encodeForStorage(),
          copied.encodeForStorage(),
        );
        songs.setSplitPlaylistTypes(true);
        expect(
          c.read(playlistPlanProvider).encodeForCli(),
          original.encodeForCli(),
        );
        // With scene editing enabled, copying still retains both independent lists.
        songs.copyGameLayout(catalog);
        expect(
          c
              .read(playlistPlanProvider)
              .assignmentsForRadio('R9', 'FreeRoam')
              .single
              .source,
          tracks[2].source,
        );
        expect(
          c
              .read(playlistPlanProvider)
              .assignmentsForRadio('R9', 'Event')
              .single
              .source,
          tracks[24].source,
        );
      },
    );
  }

  test('two disjoint 22-song lists need 44 physical positions', () {
    final dir = project();
    final plan = splitPlan(dir, tracksFor(dir));
    final policy = PlaylistCapacityPolicy({
      'R9': {'FreeRoam': 22, 'Event': 22},
    });
    final violations = policy.violations(plan);
    expect(violations, hasLength(1));
    expect(violations.single.type, isNull);
    expect(violations.single.count, 44);
    expect(plan.canFitRadioSources('R9', const [], 22), isFalse);
    expect(plan.canFitRadioSources('R9', const [], 4096), isTrue);
  });

  test(
    'package roundtrip restores scene order instead of physical bank indexes',
    () async {
      final dir = project();
      final tracks = tracksFor(dir);
      final manifest = File(
        packageManifestPath(FhRadioStudioProject.currentPackageDir(dir.path)),
      );
      manifest.parent.createSync(recursive: true);
      manifest.writeAsStringSync(
        jsonEncode({
          'radio': 9,
          'station': 'Radio 9',
          'radios': [
            {
              'radio': 9,
              'station': 'Radio 9',
              'music': [
                for (final t in tracks)
                  {'source': t.source, 'display_name': t.title},
              ],
              'assignments': [
                for (var i = 0; i < tracks.length; i++)
                  {
                    'source_index': i,
                    'slot_index': i,
                    'playlist_entry': true,
                    'playlist_types': [i < 22 ? 'FreeRoam' : 'Event'],
                    'playlist_slots': {
                      i < 22 ? 'FreeRoam' : 'Event': i % 22 + 1,
                    },
                  },
              ],
            },
          ],
        }),
        encoding: utf8,
      );
      final c = await containerFor(dir, tracks);
      final summary = c.read(studioProvider).lastPackageSummary!;
      expect(summary.assignments.last.slot, 44);
      expect(summary.assignments.last.slotForPlaylist('Event'), 22);
      final plan = c.read(effectivePlaylistPlanProvider);
      expect(
        plan.assignmentsForRadio('R9', 'Event').map((a) => a.slot),
        List.generate(22, (i) => i + 1),
      );
      expect(c.read(playlistProvider).splitPlaylistTypes, isTrue);
    },
  );

  test('explicit builtin choice counts as a scenario difference', () {
    final plan = const PlaylistPlan.empty().restoreBuiltin(
      radioCode: 'R9',
      playlistType: 'Event',
    );
    expect(plan.hasSplitPlaylistDifferences, isTrue);
    expect(
      plan.syncPlaylistTypesFrom('Event').hasSplitPlaylistDifferences,
      isFalse,
    );
  });

  test(
    'last scene member cannot be removed or moved to another scene',
    () async {
      final dir = project();
      FhRadioStudioProject.writeSettings(dir.path, expansionEnabled: true);
      final tracks = tracksFor(dir);
      final c = await containerFor(dir, tracks);
      final songs = c.read(playlistProvider.notifier);
      songs.setSplitPlaylistTypes(true);
      final singleScene = const PlaylistPlan.empty()
          .assign(
            source: tracks[0].source,
            radioCode: 'R9',
            playlistType: 'FreeRoam',
            slot: 1,
            projectDir: dir.path,
          )
          .assign(
            source: tracks[22].source,
            radioCode: 'R9',
            playlistType: 'Event',
            slot: 1,
            projectDir: dir.path,
          );
      c.read(playlistPlanProvider.notifier).replaceWith(singleScene);
      songs.unassign(tracks[0].id, radioCode: 'R9', playlistType: 'FreeRoam');
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        singleScene.encodeForCli(),
      );
      expect(songs.lastEditBlockedReason, contains('暂不支持清空'));
      expect(
        songs.assignManyToRadio(
          [tracks[0].id],
          'R9',
          'Event',
          maxSlots: 4096,
          originRadioCode: 'R9',
          originPlaylistType: 'FreeRoam',
        ),
        isFalse,
      );
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        singleScene.encodeForCli(),
      );
      songs.restoreBuiltin('R9', 'FreeRoam');
      expect(songs.lastEditBlockedReason, contains('一边原版、一边自建'));
      expect(
        c.read(playlistPlanProvider).encodeForCli(),
        singleScene.encodeForCli(),
      );
      // Copying from the pool is different from moving the last member.
      expect(
        songs.assignManyToRadio([tracks[0].id], 'R9', 'Event', maxSlots: 4096),
        isTrue,
      );
      expect(
        c.read(playlistPlanProvider).assignmentsForRadio('R9', 'FreeRoam'),
        hasLength(1),
      );
      expect(
        c.read(playlistPlanProvider).assignmentsForRadio('R9', 'Event'),
        hasLength(2),
      );
    },
  );
}
