import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/song_browse.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/song_browse_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

PoolTrack _track(String id, {String? assignedTo}) => PoolTrack(
  id: id,
  title: id,
  artist: 'Scene test',
  source: 'D:/scene-browse/sources/$id.wav',
  durationSec: 180,
  bpm: 120,
  key: '',
  configured: false,
  confirmed: 0,
  assignedTo: assignedTo,
  added: '',
);

Widget _app(Widget child) => MaterialApp(
  theme: buildAppTheme(brightness: Brightness.light, accent: AppAccent.lime),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  final free = _track('free', assignedTo: 'R1');
  final event = _track('event', assignedTo: 'R1');
  final both = _track('both', assignedTo: 'R1');
  final unassigned = _track('unassigned');
  final songs = [free, event, both, unassigned];

  test(
    'default ordering uses filenames rather than title, artist or folder',
    () {
      PoolTrack song(String source, String title, String artist) => PoolTrack(
        id: source,
        source: source,
        title: title,
        artist: artist,
        durationSec: 180,
        bpm: 120,
        key: '',
        configured: false,
        confirmed: 0,
        added: '',
      );
      final a = song(r'Z:\music\Alpha.wav', 'Z title', 'C artist');
      final b = song('A:/music/beta.wav', 'A title', 'B artist');
      final c = song('A:/music/Gamma.wav', 'B title', 'A artist');
      final input = [c, b, a];
      expect(const SongBrowse().sort, SongSort.filename);
      expect(browseSongs(input, const SongBrowse()), [a, b, c]);
      expect(browseSongs(input, const SongBrowse(descending: true)), [c, b, a]);
      expect(browseSongs(input, const SongBrowse(sort: SongSort.artist)), [
        c,
        b,
        a,
      ]);
      expect(browseSongs(input, const SongBrowse(sort: SongSort.title)), [
        b,
        c,
        a,
      ]);
      expect(input, [c, b, a]);
    },
  );

  testWidgets(
    'narrow pool keeps filters on one row and equally wide action buttons',
    (tester) async {
      var value = const SongBrowse();
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 260,
            child: StatefulBuilder(
              builder: (context, setState) => SongBrowseControls(
                value: value,
                compact: true,
                showSearch: false,
                showScene: true,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      );
      final direction = find.widgetWithText(RmButton, '正序');
      final scene = find.byKey(const ValueKey('song-scene-filter'));
      expect(tester.getSize(direction).width, songBrowseActionWidth);
      expect(tester.getSize(scene).width, songBrowseActionWidth);
      expect(tester.getTopRight(direction).dx, tester.getTopRight(scene).dx);
      expect(
        tester.getTopLeft(find.text('全部状态')).dy,
        tester.getTopLeft(find.text('全部电台')).dy,
      );
      for (final label in ['文件名称', '全部状态', '全部电台']) {
        final text = find.text(label);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      }
      await tester.tap(find.byType(DropdownButton<SongSort>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌手名称').last);
      await tester.pumpAndSettle();
      expect(value.sort, SongSort.artist);
      expect(tester.takeException(), isNull);
    },
  );
  final plan = const PlaylistPlan.empty()
      .assign(
        source: free.source,
        radioCode: 'R1',
        playlistType: 'FreeRoam',
        slot: 1,
      )
      .assign(
        source: event.source,
        radioCode: 'R1',
        playlistType: 'Event',
        slot: 1,
      )
      .assign(
        source: both.source,
        radioCode: 'R1',
        playlistType: 'FreeRoam',
        slot: 2,
      )
      .assign(
        source: both.source,
        radioCode: 'R2',
        playlistType: 'Event',
        slot: 1,
      );

  List<String> ids(SongBrowse options, {bool split = true}) => browseSongs(
    songs,
    options,
    plan: plan,
    splitTypes: split,
  ).map((track) => track.id).toList();

  test(
    'both scenes contain shared songs and all contains unassigned songs',
    () {
      expect(ids(const SongBrowse()), ['both', 'event', 'free', 'unassigned']);
      expect(ids(const SongBrowse(scene: SongSceneFilter.freeRoam)), [
        'both',
        'free',
      ]);
      expect(ids(const SongBrowse(scene: SongSceneFilter.event)), [
        'both',
        'event',
      ]);
      // Scene membership is independent of timing readiness and first station.
      expect(both.configured, isFalse);
      expect(both.freeRoamOnly, isFalse);
    },
  );

  test('scene and station filters must match the same assignment', () {
    expect(ids(const SongBrowse(scene: SongSceneFilter.event, station: 'R1')), [
      'event',
    ]);
    expect(
      ids(const SongBrowse(scene: SongSceneFilter.freeRoam, station: 'R2')),
      isEmpty,
    );
    expect(ids(const SongBrowse(scene: SongSceneFilter.event, station: 'R2')), [
      'both',
    ]);
    // The second station must be discoverable even though assignedTo is R1.
    expect(ids(const SongBrowse(station: 'R2')), ['both']);
  });

  test(
    'turning split off ignores retained scene but preserves station filter',
    () {
      expect(
        ids(const SongBrowse(scene: SongSceneFilter.event), split: false),
        ['both', 'event', 'free', 'unassigned'],
      );
      expect(
        ids(
          const SongBrowse(scene: SongSceneFilter.freeRoam, station: 'R2'),
          split: false,
        ),
        ['both'],
      );
    },
  );

  test(
    'scene lookup uses canonical source paths and ignores removed assignments',
    () {
      final differentlyCased = const PlaylistPlan.empty().assign(
        source: both.source.toUpperCase(),
        radioCode: 'R3',
        playlistType: 'Event',
        slot: 1,
      );
      final options = const SongBrowse(scene: SongSceneFilter.event);
      expect(
        browseSongs([both], options, plan: differentlyCased, splitTypes: true),
        [both],
      );
      final removed = differentlyCased.unassign(both.source);
      expect(
        browseSongs([both], options, plan: removed, splitTypes: true),
        isEmpty,
      );
    },
  );

  test('scene matching combines with search and timing status filters', () {
    expect(
      ids(
        const SongBrowse(
          scene: SongSceneFilter.freeRoam,
          search: 'BOTH',
          filter: SongFilter.unconfigured,
        ),
      ),
      ['both'],
    );
    expect(
      ids(
        const SongBrowse(
          scene: SongSceneFilter.event,
          filter: SongFilter.unassigned,
        ),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'scene controls appear only when enabled and preserve other filters',
    (tester) async {
      final value = ValueNotifier(
        const SongBrowse(
          search: 'night',
          station: 'R1',
          filter: SongFilter.assigned,
          scene: SongSceneFilter.freeRoam,
        ),
      );
      final showScene = ValueNotifier(false);
      final notifications = <SongBrowse>[];
      addTearDown(value.dispose);
      addTearDown(showScene.dispose);

      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 760,
            child: ValueListenableBuilder<bool>(
              valueListenable: showScene,
              builder: (context, enabled, child) =>
                  ValueListenableBuilder<SongBrowse>(
                    valueListenable: value,
                    builder: (context, options, child) => SongBrowseControls(
                      value: options,
                      showScene: enabled,
                      onChanged: (next) {
                        notifications.add(next);
                        value.value = next;
                      },
                    ),
                  ),
            ),
          ),
        ),
      );
      const sceneKey = ValueKey('song-scene-filter');
      expect(find.byKey(sceneKey), findsNothing);
      showScene.value = true;
      await tester.pump();
      final scene = find.byKey(sceneKey);
      expect(scene, findsOneWidget);
      expect(tester.widget<RmButton>(scene).label, '漫游');
      await tester.tap(scene);
      await tester.pump();
      expect(value.value.scene, SongSceneFilter.event);
      expect(value.value.search, 'night');
      expect(value.value.station, 'R1');
      expect(value.value.filter, SongFilter.assigned);
      expect(notifications.length, 1);

      showScene.value = false;
      await tester.pump();
      expect(find.byKey(sceneKey), findsNothing);
      showScene.value = true;
      await tester.pump();
      expect(tester.widget<RmButton>(find.byKey(sceneKey)).label, '比赛');
      expect(notifications.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [
    (name: 'wide', width: 1100.0, compact: false),
    (name: 'narrow', width: 500.0, compact: false),
    (name: 'compact pool', width: 300.0, compact: true),
  ]) {
    testWidgets(
      '${layout.name} search keeps its height when clear button appears',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final value = ValueNotifier(const SongBrowse());
        final notifications = <SongBrowse>[];
        addTearDown(value.dispose);
        await tester.pumpWidget(
          _app(
            SizedBox(
              width: layout.width,
              child: ValueListenableBuilder<SongBrowse>(
                valueListenable: value,
                builder: (context, options, child) => SongBrowseControls(
                  value: options,
                  compact: layout.compact,
                  showScene: true,
                  onChanged: (next) {
                    notifications.add(next);
                    value.value = next;
                  },
                ),
              ),
            ),
          ),
        );
        final search = find.byKey(const ValueKey('song-browse-search'));
        final clear = find.byKey(const ValueKey('song-browse-clear-search'));
        final emptySize = tester.getSize(search);
        final emptySceneTop = tester
            .getTopLeft(find.byKey(const ValueKey('song-scene-filter')))
            .dy;
        expect(clear, findsNothing);

        await tester.enterText(search, 'city 中文');
        await tester.pump();
        expect(clear, findsOneWidget);
        expect(tester.getSize(search), emptySize);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('song-scene-filter'))).dy,
          emptySceneTop,
        );
        expect(
          tester.getSize(clear).height,
          lessThanOrEqualTo(emptySize.height),
        );
        expect(notifications.single.search, 'city 中文');

        await tester.tap(clear);
        await tester.pump();
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(notifications.last.search, isEmpty);
        expect(notifications.length, 2);
        expect(clear, findsNothing);
        expect(tester.getSize(search), emptySize);

        // A restored page filter must update the existing field, not only its
        // initial value, and it must not produce another user-change callback.
        value.value = value.value.copyWith(search: 'external filter');
        await tester.pump();
        expect(
          tester.widget<TextField>(search).controller!.text,
          'external filter',
        );
        expect(clear, findsOneWidget);
        expect(notifications.length, 2);
        value.value = value.value.copyWith(search: '');
        await tester.pump();
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(clear, findsNothing);
        expect(notifications.length, 2);
        expect(tester.getSize(search), emptySize);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
