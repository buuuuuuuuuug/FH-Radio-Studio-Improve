import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/router.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/unsaved_edits.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';

Future<void> doubleClick(WidgetTester tester, Finder card) async {
  await tester.tap(card);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(card);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<({GoRouter router, PlaylistPlan plan, ProviderContainer container})>
setupPlaylist(WidgetTester tester, {bool gameView = false}) async {
  tester.view.physicalSize = const Size(1800, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final temp = Directory.systemTemp.createTempSync('playlist-double-edit-');
  addTearDown(() => temp.deleteSync(recursive: true));
  FhRadioStudioProject.ensure(temp.path);
  final baseline = File(
    '${temp.path}/backups/baseline-current/baseline_manifest.json',
  );
  baseline.parent.createSync(recursive: true);
  baseline.writeAsStringSync(
    '{"kind":"game_baseline","state":"current","files":[]}',
  );
  SharedPreferences.setMockInitialValues({'rm.studio.projectDir': temp.path});
  final prefs = await SharedPreferences.getInstance();
  final plan = const PlaylistPlan.empty().assign(
    source: kCustomPool.first.source,
    radioCode: 'R1',
    playlistType: 'FreeRoam',
    slot: 1,
  );
  final catalog = PlaylistCatalog(
    origin: gameView
        ? PlaylistCatalogOrigin.game
        : PlaylistCatalogOrigin.package,
    sourcePath: 'fixture.xml',
    radios: [kRadios.first],
    modes: const {'R1': StationMode.custom},
    freeRoamTracks: const {
      'R1': [
        TrackRef(
          id: 'catalog-local',
          title: 'Different displayed game title',
          artist: 'Game artist',
          durationSec: 180,
          soundName: 'LOCAL',
          modded: true,
        ),
        TrackRef(
          id: 'catalog-original',
          title: 'Original built-in song',
          artist: 'Game artist',
          durationSec: 180,
          soundName: 'ORIGINAL',
        ),
      ],
    },
    eventTracks: const {},
    sourceBySoundName: {'LOCAL': kCustomPool.first.source},
  );
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      studioProvider.overrideWith((ref) => _FixtureController(prefs)),
      realPoolTracksProvider.overrideWithValue(kCustomPool),
      playlistCatalogProvider.overrideWithValue(catalog),
      playlistCatalogViewProvider.overrideWith(
        (ref) =>
            gameView ? PlaylistCatalogView.game : PlaylistCatalogView.package,
      ),
      effectivePlaylistPlanProvider.overrideWithValue(
        gameView ? const PlaylistPlan.empty() : plan,
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: RmRoutes.playlist,
    routes: [
      GoRoute(
        path: RmRoutes.playlist,
        builder: (context, state) => const Scaffold(body: PlaylistScreen()),
      ),
      GoRoute(
        path: RmRoutes.editorPath,
        onExit: (context, state) => container
            .read(unsavedEditsProvider)
            .confirm(context, key: 'editor'),
        builder: (_, state) => Scaffold(
          body: ReplaceEditorScreen(
            trackId: state.pathParameters['trackId']!,
            returnToPlaylist: state.uri.queryParameters['from'] == 'playlist',
            enableAudio: false,
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
      ),
    ),
  );
  await tester.pump();
  return (router: router, plan: plan, container: container);
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'double click edits once, ordinary click and dragging do not edit',
    (tester) async {
      var opened = 0;
      var dragged = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: Draggable<String>(
                  data: 'song',
                  onDragStarted: () => dragged++,
                  feedback: const SizedBox(width: 200, height: 60),
                  child: TrackCard.fromPoolTrack(
                    kCustomPool.first,
                    onOpenEditor: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(TrackCard);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 350));
      expect(opened, 0);
      await tester.drag(card, const Offset(120, 80));
      await tester.pump();
      expect(dragged, 1);
      expect(opened, 0);
      await doubleClick(tester, card);
      expect(opened, 1);
      expect(find.byTooltip('双击进入编辑；拖动可调整排序'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'station double click opens correct song and Esc keeps playlist search and draft',
    (tester) async {
      final f = await setupPlaylist(tester);
      final search = find.byKey(const ValueKey('playlist-search'));
      final searchHeight = tester.getSize(search).height;
      await tester.enterText(search, 'midnight');
      await tester.pump();
      expect(tester.getSize(search).height, searchHeight);
      final card = find.descendant(
        of: find.byKey(const ValueKey('playlist-radio-column-R1')),
        matching: find.byType(TrackCard),
      );
      await doubleClick(tester, card);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReplaceEditorScreen>(find.byType(ReplaceEditorScreen))
            .returnToPlaylist,
        isTrue,
      );
      expect(
        tester
            .widget<ReplaceEditorScreen>(find.byType(ReplaceEditorScreen))
            .trackId,
        kCustomPool.first.id,
      );
      expect(find.text('播放列表 · Esc 返回'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        f.router.routeInformationProvider.value.uri.path,
        RmRoutes.playlist,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('playlist-search')))
            .controller!
            .text,
        'midnight',
      );
      expect(f.container.read(effectivePlaylistPlanProvider), f.plan);
      expect(find.textContaining('双击自建曲目进入编辑'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playlist-clear-search')));
      await tester.pump();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(tester.getSize(search).height, searchHeight);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pool shortcut respects unsaved cancel and discard before returning',
    (tester) async {
      final f = await setupPlaylist(tester);
      final card = find
          .descendant(
            of: find.byKey(const ValueKey('playlist-pool-side-panel')),
            matching: find.byType(TrackCard),
          )
          .first;
      final id = tester.widget<TrackCard>(card).title;
      await doubleClick(tester, card);
      await tester.pumpAndSettle();
      final song = kCustomPool.firstWhere((t) => t.title == id);
      expect(
        tester
            .widget<ReplaceEditorScreen>(find.byType(ReplaceEditorScreen))
            .trackId,
        song.id,
      );
      var dirty = true;
      f.container.read(unsavedEditsProvider).entries['editor'] = PendingEdit(
        label: 'Fixture unsaved song',
        dirty: () => dirty,
        save: () => dirty = false,
        discard: () => dirty = false,
      );
      await tester.tap(find.text('播放列表 · Esc 返回'));
      await tester.pumpAndSettle();
      expect(find.text('存在未保存的修改'), findsOneWidget);
      await tester.tap(find.text('取消返回'));
      await tester.pumpAndSettle();
      expect(find.byType(ReplaceEditorScreen), findsOneWidget);
      await tester.tap(find.text('播放列表 · Esc 返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(
        f.router.routeInformationProvider.value.uri.path,
        RmRoutes.playlist,
      );
      expect(dirty, isFalse);
      expect(f.container.read(effectivePlaylistPlanProvider), f.plan);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('game view is read-only even when the song has a local source', (
    tester,
  ) async {
    final f = await setupPlaylist(tester, gameView: true);
    expect(find.text('2 / 2'), findsOneWidget);
    final cards = find.descendant(
      of: find.byKey(const ValueKey('playlist-radio-column-R1')),
      matching: find.byType(TrackCard),
    );
    expect(tester.widget<TrackCard>(cards.at(0)).locked, isTrue);
    expect(tester.widget<TrackCard>(cards.at(0)).onOpenEditor, isNull);
    expect(find.textContaining('双击自建曲目进入编辑'), findsNothing);
    expect(tester.widget<TrackCard>(cards.at(1)).onOpenEditor, isNull);
    await doubleClick(tester, cards.at(1));
    await tester.pump();
    expect(f.router.routeInformationProvider.value.uri.path, RmRoutes.playlist);
    await doubleClick(tester, cards.at(0));
    await tester.pumpAndSettle();
    expect(find.byType(ReplaceEditorScreen), findsNothing);
    expect(f.router.routeInformationProvider.value.uri.path, RmRoutes.playlist);
    expect(tester.takeException(), isNull);
  });
}

class _FixtureController extends StudioController {
  _FixtureController(super.prefs);
  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}
