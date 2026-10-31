import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/playlist/playlist.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/widgets/playlist_toolbar_row.dart';
import 'package:fh_radio_studio/widgets/rm_chip.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/split_playlist_setting.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'studio_v18_workflow_test.dart' as fixtures;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [850.0, 1200.0, 1600.0]) {
    testWidgets(
      'playlist toolbar stays aligned and reports unsaved assignments at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = await fixtures.fixture();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: ProviderScope(
              overrides: [
                automaticFeatureToursProvider.overrideWithValue(false),
              ],
              child: MaterialApp(
                theme: buildAppTheme(
                  brightness: Brightness.light,
                  accent: AppAccent.lime,
                ),
                home: const Scaffold(body: PlaylistScreen()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final status = find.byKey(const ValueKey('playlist-save-status'));
        expect(find.byType(PlaylistToolbarRow), findsOneWidget);
        if (width >= 1200) {
          final copy = find.widgetWithText(RmButton, '复制游戏内排布');
          final split = find.byType(SplitPlaylistSetting);
          expect(
            tester.getRect(split).left,
            greaterThan(tester.getRect(copy).right),
          );
          expect(
            tester.getCenter(split).dy,
            closeTo(tester.getCenter(copy).dy, 1),
          );
        }
        expect(tester.widget<RmChip>(status).label, endsWith('已保存'));
        final search = find.byKey(const ValueKey('playlist-search'));
        final height = tester.getSize(search).height;
        expect(
          c
              .read(playlistProvider.notifier)
              .assignManyToRadio(
                [c.read(playlistProvider).pool.first.id],
                'R1',
                'FreeRoam',
                maxSlots: 2,
              ),
          isTrue,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<RmChip>(status).label, '1 首分配 · 未保存');
        expect(
          tester
              .widget<RmButton>(find.byKey(const ValueKey('playlist-save')))
              .label,
          '保存播放列表',
        );
        final undo = find.byKey(const ValueKey('playlist-undo'));
        expect(
          (tester.getCenter(status).dy - tester.getCenter(undo).dy).abs(),
          lessThan(1),
        );
        await tester.tap(undo);
        await tester.pumpAndSettle();
        expect(tester.widget<RmChip>(status).label, endsWith('已保存'));
        expect(tester.getSize(search).height, height);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
