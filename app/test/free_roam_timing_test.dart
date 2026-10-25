import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/playlist_timing_requirements.dart';
import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/song_browse.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';

void main() {
  test('race use in any station cancels the free-roam timing exemption', () {
    final file = File('source.wav').absolute;
    var plan = const PlaylistPlan.empty().assign(
      source: file.path,
      radioCode: 'R9',
      playlistType: 'FreeRoam',
      slot: 1,
    );
    expect(isFreeRoamOnlySource(plan, file.path), isTrue);
    expect(
      isFreeRoamOnlySource(plan, File('unassigned.wav').absolute.path),
      isFalse,
    );
    plan = plan.assign(
      source: file.path,
      radioCode: 'R1',
      playlistType: 'Event',
      slot: 1,
    );
    expect(isFreeRoamOnlySource(plan, file.path), isFalse);
  });

  test('free-roam readiness never fabricates manual confirmation', () {
    final root = Directory.systemTemp.createTempSync('roam-ready-');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/song.wav')..writeAsBytesSync([0]);
    var plan = const PlaylistPlan.empty().assign(
      source: source.path,
      radioCode: 'R9',
      playlistType: 'FreeRoam',
      slot: 1,
    );
    final free = buildRealPoolTracks([
      source.path,
    ], assignments: plan.assignments).single;
    expect(free.readyForBuild, isTrue);
    expect(free.configured, isFalse);
    expect(free.confirmed, 0);
    expect(
      browseSongs([free], const SongBrowse(filter: SongFilter.configured)),
      [free],
    );
    expect(
      browseSongs([free], const SongBrowse(filter: SongFilter.unconfigured)),
      isEmpty,
    );
    expect(free.copyWith(slot: 2).freeRoamOnly, isTrue);
    plan = plan.assign(
      source: source.path,
      radioCode: 'R8',
      playlistType: 'Event',
      slot: 1,
    );
    final race = buildRealPoolTracks([
      source.path,
    ], assignments: plan.assignments).single;
    expect(race.readyForBuild, isFalse);
  });

  test('partial optional edits reach the build without becoming confirmed', () {
    final root = Directory.systemTemp.createTempSync('roam-partial-');
    addTearDown(() => root.deleteSync(recursive: true));
    FhRadioStudioProject.ensure(root.path);
    final source = File('${root.path}/sources/song.wav')..writeAsBytesSync([0]);
    File(TrackMetadataCache.configPath(root.path)).writeAsStringSync(
      jsonEncode({
        'schema_version': 2,
        'tracks': [
          {
            'source_ref': projectRefForPath(root.path, source.path),
            'track_key': trackKeyForProjectPath(root.path, source.path),
          },
        ],
      }),
    );
    TrackTimingStore.save(
      root.path,
      TrackTimingConfig(
        source: source.path,
        bpm: 120,
        markersSec: const {'TrackDrop': 1.25},
        confirmed: const {'td': false},
        updatedAt: DateTime.utc(2026),
      ),
    );
    final original = File(
      TrackTimingStore.configPath(root.path),
    ).readAsBytesSync();
    final manifest = TrackTimingStore.writeBuildManifest(
      projectDir: root.path,
      musicInputs: [source.path],
      freeRoamOnlySources: {TrackTimingConfig.keyForPath(source.path)},
    );
    expect(manifest, isNotNull);
    expect(File(manifest!).readAsStringSync(), contains('1.25'));
    expect(
      File(TrackTimingStore.configPath(root.path)).readAsBytesSync(),
      original,
    );
    expect(
      TrackTimingStore.writeBuildManifest(
        projectDir: root.path,
        musicInputs: [source.path],
      ),
      isNull,
    );
  });
}
