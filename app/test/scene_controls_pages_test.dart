import 'dart:io';

import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/song_browse_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SceneStudio extends StudioController {
  _SceneStudio(super.prefs);

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}

Future<ProviderContainer> _fixture() async {
  final dir = Directory.systemTemp.createTempSync('scene-pages-');
  addTearDown(() => dir.deleteSync(recursive: true));
  FhRadioStudioProject.ensure(dir.path);
  final baseline = File(
    '${dir.path}/backups/baseline-current/baseline_manifest.json',
  );
  baseline.parent.createSync(recursive: true);
  baseline.writeAsStringSync(
    '{"kind":"game_baseline","state":"current","files":[]}',
  );
  final tracks = [
    for (final title in ['A Roam', 'B Event', 'C Both', 'D Unassigned'])
      PoolTrack(
        id: title,
        title: title,
        artist: 'Scene Test',
        source: (File(
          '${dir.path}/sources/$title.wav',
        )..writeAsBytesSync([0])).path,
        durationSec: 180,
        bpm: 120,
        key: 'C',
        configured: true,
        confirmed: 4,
        added: '',
      ),
  ];
  SharedPreferences.setMockInitialValues({'rm.studio.projectDir': dir.path});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      studioProvider.overrideWith((ref) => _SceneStudio(prefs)),
      realPoolTracksProvider.overrideWithValue(tracks),
      playlistCatalogProvider.overrideWithValue(
        PlaylistCatalog(
          origin: PlaylistCatalogOrigin.package,
          sourcePath: 'scene-pages-fixture',
          radios: [kRadios.first],
          modes: const {'R1': StationMode.custom},
          freeRoamTracks: const {},
          eventTracks: const {},
        ),
      ),
      baselinePlaylistCatalogProvider.overrideWithValue(null),
      playlistCatalogViewProvider.overrideWith(
        (ref) => PlaylistCatalogView.package,
      ),
    ],
  );
  addTearDown(c.dispose);
  final songs = c.read(playlistProvider.notifier);
  songs.setSplitPlaylistTypes(true);
  for (final (id, type) in [
    ('A Roam', 'FreeRoam'),
    ('B Event', 'Event'),
    ('C Both', 'FreeRoam'),
    ('C Both', 'Event'),
  ]) {
    expect(songs.assignToRadio(id, 'R1', type), isTrue);
  }
  return c;
}

Future<void> _pumpPage(
  WidgetTester tester,
  ProviderContainer c,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1800, 1400);
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
        home: Scaffold(body: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _filter(WidgetTester tester, String label) async {
  final choice = find.byKey(const ValueKey('song-scene-filter'));
  await tester.ensureVisible(choice);
  for (
    var i = 0;
    i < 3 && tester.widget<RmButton>(choice).label != label;
    i++
  ) {
    await tester.tap(choice);
    await tester.pumpAndSettle();
  }
}

Finder get _pool => find.byKey(const ValueKey('playlist-pool-side-panel'));

Set<String> _poolTitles(WidgetTester tester) => tester
    .widgetList<TrackCard>(
      find.descendant(of: _pool, matching: find.byType(TrackCard)),
    )
    .map((card) => card.title)
    .toSet();

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'custom songs filter assignments and ignore scene after disabling',
    (tester) async {
      final c = await _fixture();
      await _pumpPage(tester, c, const CustomPoolScreen());
      expect(
        tester
            .widget<SongBrowseControls>(find.byType(SongBrowseControls))
            .showScene,
        isTrue,
      );
      await _filter(tester, '漫游');
      expect(find.text('A Roam'), findsOneWidget);
      expect(find.text('C Both'), findsOneWidget);
      expect(find.text('B Event'), findsNothing);
      expect(find.text('D Unassigned'), findsNothing);

      await _filter(tester, '比赛');
      expect(find.text('B Event'), findsOneWidget);
      expect(find.text('C Both'), findsOneWidget);
      expect(find.text('A Roam'), findsNothing);
      expect(find.text('D Unassigned'), findsNothing);

      c.read(playlistProvider.notifier).setSplitPlaylistTypes(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('song-scene-filter')), findsNothing);
      for (final title in ['A Roam', 'B Event', 'C Both', 'D Unassigned']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'playlist pool scene filter clears selection and hides when off',
    (tester) async {
      final c = await _fixture();
      await _pumpPage(tester, c, const PlaylistScreen());
      expect(
        tester
            .widget<SongBrowseControls>(find.byType(SongBrowseControls))
            .showScene,
        isTrue,
      );
      expect(_poolTitles(tester), {
        'A Roam',
        'B Event',
        'C Both',
        'D Unassigned',
      });
      await _filter(tester, '漫游');
      expect(_poolTitles(tester), {'A Roam', 'C Both'});

      await tester.tap(
        find.byKey(const ValueKey('playlist-multiselect-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: _pool,
          matching: find.byWidgetPredicate(
            (widget) => widget is TrackCard && widget.title == 'A Roam',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      await _filter(tester, '比赛');
      expect(_poolTitles(tester), {'B Event', 'C Both'});
      expect(find.text('已选 0'), findsOneWidget);
      expect(
        tester
            .widget<RmButton>(
              find.byKey(const ValueKey('playlist-batch-assign')),
            )
            .onPressed,
        isNull,
      );

      c.read(playlistProvider.notifier).setSplitPlaylistTypes(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('song-scene-filter')), findsNothing);
      expect(_poolTitles(tester), {
        'A Roam',
        'B Event',
        'C Both',
        'D Unassigned',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'station card copies event playlist into roam as one undo action',
    (tester) async {
      final c = await _fixture();
      final before = c.read(effectivePlaylistPlanProvider).encodeForCli();
      final eventSources = c
          .read(effectivePlaylistPlanProvider)
          .assignmentsForRadio('R1', 'Event')
          .map((assignment) => assignment.source)
          .toList();
      await _pumpPage(tester, c, const PlaylistScreen());
      final useEvent = find.byTooltip('使用比赛歌单');
      expect(useEvent, findsOneWidget);
      expect(find.textContaining('不支持一边原版、一边自建'), findsNothing);
      await tester.tap(useEvent);
      await tester.pumpAndSettle();
      expect(c.read(effectivePlaylistPlanProvider).encodeForCli(), before);
      expect(find.textContaining('不支持一边原版、一边自建'), findsOneWidget);
      await tester.tap(find.widgetWithText(RmButton, '使用比赛歌单'));
      await tester.pumpAndSettle();
      final plan = c.read(effectivePlaylistPlanProvider);
      expect(
        plan
            .assignmentsForRadio('R1', 'FreeRoam')
            .map((a) => a.source)
            .toList(),
        eventSources,
      );
      expect(
        plan.assignmentsForRadio('R1', 'Event').map((a) => a.source).toList(),
        eventSources,
      );
      await tester.tap(find.byKey(const ValueKey('playlist-undo')));
      await tester.pumpAndSettle();
      expect(c.read(effectivePlaylistPlanProvider).encodeForCli(), before);
      expect(tester.takeException(), isNull);
    },
  );
}
