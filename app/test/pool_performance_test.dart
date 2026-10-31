import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:flutter/gestures.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';

void main() {
  test('song index refreshes when metadata changes or disappears', () {
    final root = Directory.systemTemp.createTempSync('song-index-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/.fh-radio-studio/track_metadata.json');
    file.parent.createSync();
    file.writeAsStringSync(
      jsonEncode({
        'tracks': [
          {'track_key': 'first', 'source_ref': 'fh-project:/sources/one.wav'},
        ],
      }),
    );
    expect(
      TrackMetadataCache.resolveTrackKey(root.path, 'first'),
      endsWith('one.wav'),
    );
    file.writeAsStringSync(
      jsonEncode({
        'tracks': [
          {
            'track_key': 'second-long-key',
            'source_ref': 'fh-project:/sources/two.wav',
          },
        ],
      }),
    );
    expect(TrackMetadataCache.resolveTrackKey(root.path, 'first'), isNull);
    expect(
      TrackMetadataCache.resolveTrackKey(root.path, 'second-long-key'),
      endsWith('two.wav'),
    );
    file.deleteSync();
    expect(TrackMetadataCache.assetIndex(root.path), isEmpty);
  });

  testWidgets(
    'large song pool renders visible rows and restores deep position',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': 'performance-fixture',
      });
      final prefs = await SharedPreferences.getInstance();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1500, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final tracks = List.generate(
        229,
        (i) => PoolTrack(
          id: 'fixture:$i',
          title: 'Song ${i.toString().padLeft(3, '0')}',
          artist: 'Artist',
          source: '/fixture/song-$i.wav',
          durationSec: 180,
          bpm: 120,
          key: '',
          configured: true,
          confirmed: 4,
          added: 'today',
        ),
      );
      const catalog = PlaylistCatalog(
        origin: PlaylistCatalogOrigin.game,
        sourcePath: null,
        radios: [],
        modes: {},
        freeRoamTracks: {},
        eventTracks: {},
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => _FixtureController(prefs)),
            realPoolTracksProvider.overrideWithValue(tracks),
            effectivePlaylistPlanProvider.overrideWithValue(
              const PlaylistPlan.empty(),
            ),
            gamePlaylistCatalogProvider.overrideWithValue(catalog),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) =>
                    show ? const CustomPoolScreen() : const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder rows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('pool-row:'),
      );
      expect(rows().evaluate().length, lessThan(25));
      expect(find.text('Song 228'), findsNothing);
      final source = find.byKey(const ValueKey('pool-source-directory'));
      final actions = find.byKey(const ValueKey('pool-library-actions'));
      void checkHeader() {
        final sourceRect = tester.getRect(source);
        final actionRect = tester.getRect(actions);
        expect(sourceRect.overlaps(actionRect), isFalse);

        expect(
          actionRect.right,
          lessThanOrEqualTo(tester.view.physicalSize.width),
        );
        expect(
          sourceRect.right,
          lessThanOrEqualTo(tester.view.physicalSize.width),
        );
        if ((sourceRect.center.dy - actionRect.center.dy).abs() < 1) {
          expect(sourceRect.width, greaterThanOrEqualTo(220));
          expect(actionRect.left - sourceRect.right, greaterThanOrEqualTo(16));
        } else {
          expect(sourceRect.top - actionRect.bottom, greaterThanOrEqualTo(8));
        }
      }

      checkHeader();
      final button = find.byKey(const ValueKey('pool-preview:fixture:0:td'));
      expect(
        tester.getSize(button).width,
        greaterThan(tester.getSize(button).height),
      );
      expect(tester.getSize(button).height, 26);
      final delete = find.byTooltip('删除').first;
      final action = find.text('操作');
      final view = find.ancestor(
        of: find.text('查看').first,
        matching: find.byType(RmButton),
      );
      expect(
        tester.getTopLeft(action).dx,
        closeTo(tester.getTopLeft(view).dx, 1),
      );
      tester.view.physicalSize = const Size(1200, 1000);
      await tester.pumpAndSettle();
      checkHeader();
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(960, 1000);
      await tester.pumpAndSettle();
      checkHeader();
      expect(tester.getSize(find.text('Song 000')).width, greaterThan(100));
      expect(tester.getBottomRight(delete).dx, lessThan(920));
      expect(tester.getSize(button).width, 36);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1500, 1000);
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(find.text('回到顶部'), findsNothing);
      tester.binding.handlePointerEvent(
        const PointerScrollEvent(
          position: Offset(20, 400),
          scrollDelta: Offset(0, 640),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(500));
      final topButton = find.byKey(const ValueKey('scroll-to-top-button'));
      expect(tester.getSize(topButton).height, greaterThan(32));
      expect(tester.getCenter(topButton).dx, closeTo(750, 1));
      scroll.jumpTo(12000);
      await tester.pumpAndSettle();
      expect(rows().evaluate().length, lessThan(25));
      final remembered = scroll.offset;
      visible.value = false;
      await tester.pumpAndSettle();
      visible.value = true;
      await tester.pumpAndSettle();
      final restored = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(restored.offset, closeTo(remembered, 0.01));
      expect(rows().evaluate().length, lessThan(25));
      await tester.tap(find.text('回到顶部'));
      await tester.pumpAndSettle();
      expect(restored.offset, 0);
      expect(find.text('回到顶部'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _FixtureController extends StudioController {
  _FixtureController(super.prefs);
  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}
