import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/screens/dashboard.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/screens/project_picker.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/tweaks/tweaks_panel.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;

class _GuideStudio extends StudioController {
  _GuideStudio(super.prefs);
  @override
  Future<void> startupFullCheckOnce() async {}
}

Future<ProviderContainer> setup(
  WidgetTester t,
  Widget screen, {
  double width = 1440,
}) async {
  t.view.physicalSize = Size(width, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await fixture.fixture();
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      automaticFeatureToursProvider.overrideWithValue(true),
      studioProvider.overrideWith((ref) => _GuideStudio(prefs)),
      playlistCatalogProvider.overrideWithValue(
        PlaylistCatalog(
          origin: PlaylistCatalogOrigin.package,
          sourcePath: 'tour-test',
          radios: kRadios,
          modes: {for (final r in kRadios) r.code: StationMode.custom},
          freeRoamTracks: const {},
          eventTracks: const {},
        ),
      ),
      baselinePlaylistCatalogProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  container.read(editorOptionsProvider.notifier).update(expansionEnabled: true);
  await t.pumpWidget(
    UncontrolledProviderScope(container: container, child: helpers.app(screen)),
  );
  await t.pumpAndSettle();
  return container;
}

Future<void> checkSteps(
  WidgetTester t,
  List<String> titles, {
  Map<String, String> anchors = const {},
}) async {
  for (var i = 0; i < titles.length; i++) {
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.semanticsLabel == '功能介绍：${titles[i]}',
      ),
      findsOneWidget,
      reason: 'Missing introduction: ${titles[i]}',
    );
    final painter =
        t
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('feature-tour-highlight')),
                )
                .painter
            as dynamic;
    expect(painter.rect, isNotNull, reason: 'Missing target: ${titles[i]}');
    final anchor = anchors[titles[i]];
    if (anchor != null) {
      final target = find.byWidgetPredicate(
        (widget) => widget is TourAnchor && widget.id == anchor,
      );
      expect(target, findsOneWidget);
      final expected = t.getRect(target).inflate(5);
      final actual = painter.rect as Rect;
      expect(
        (actual.topLeft - expected.topLeft).distance,
        lessThan(1),
        reason: 'Incorrect target for ${titles[i]}',
      );
      expect(
        (actual.bottomRight - expected.bottomRight).distance,
        lessThan(1),
        reason: 'Target includes other settings: ${titles[i]}',
      );
    }
    await t.tap(find.text(i == titles.length - 1 ? '知道了' : '下一步'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }
  expect(find.byKey(const ValueKey('feature-tour-highlight')), findsNothing);
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('project picker introduces the first-use entry points', (
    t,
  ) async {
    await setup(t, const ProjectPickerScreen());
    await checkSteps(t, ['从工程开始', '边用边了解']);
    expect(find.text('新建工程'), findsOneWidget);
  });
  for (final width in [1440.0, 960.0]) {
    testWidgets(
      'basics introduces each setting with its own highlight at width $width',
      (t) async {
        final container = await setup(t, const DashboardScreen(), width: width);
        expect(
          find.byKey(const ValueKey('split-playlist-setting')),
          findsOneWidget,
        );
        expect(find.text('还原默认'), findsNothing);
        await checkSteps(
          t,
          [
            '游戏与语言',
            '分析模式',
            '同步循环',
            '电台扩容',
            'SeamlessLoopMusic',
            '分场景编辑',
            '检查与写入',
          ],
          anchors: {
            '游戏与语言': 'game',
            '分析模式': 'analysis',
            '同步循环': 'sync',
            '电台扩容': 'expansion',
            'SeamlessLoopMusic': 'seamless',
            '分场景编辑': 'split',
          },
        );
        final splitSwitch = find.descendant(
          of: find.byKey(const ValueKey('split-playlist-setting')),
          matching: find.byType(Switch),
        );
        expect(t.widget<Switch>(splitSwitch).value, isFalse);
        await Scrollable.ensureVisible(t.element(splitSwitch), alignment: .5);
        await t.pumpAndSettle();
        await t.tap(splitSwitch);
        await t.pumpAndSettle();
        expect(find.text('分开编辑漫游和比赛？'), findsOneWidget);
        await t.tap(find.text('打开'));
        await t.pumpAndSettle();
        expect(container.read(playlistProvider).splitPlaylistTypes, isTrue);
        expect(t.widget<Switch>(splitSwitch).value, isTrue);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('library introduces import, browse and songs on the real page', (
    t,
  ) async {
    await setup(t, const CustomPoolScreen());
    await checkSteps(t, ['添加歌曲', '查找与迁移', '歌曲卡片']);
  });
  testWidgets('playlist introduces view, board and build on the real page', (
    t,
  ) async {
    await setup(t, const PlaylistScreen());
    await checkSteps(t, ['查看与编辑', '分场景编辑', '搜索歌曲', '电台列数与高度', '安排电台', '保存与构建']);
  });
  for (final embedded in [false, true]) {
    testWidgets(
      'settings introduction scrolls in ${embedded ? "embedded" : "full"} layout',
      (t) async {
        await setup(
          t,
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: embedded ? 220 : 1000,
              child: TweaksPanel(embedded: embedded),
            ),
          ),
        );
        await checkSteps(t, ['外观与布局', '调整工作区', '快捷键与塞壬唱片']);
      },
    );
  }
  testWidgets('song and refinement tours preserve markers and unsaved state', (
    t,
  ) async {
    final c = await setup(
      t,
      const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
    );
    final notifier = c.read(replaceEditorProvider('p1').notifier);
    final before = {...notifier.state.markerSeconds};
    final dirty = notifier.state.dirty;
    await checkSteps(t, ['四组时间点', '波形与播放', '时间组详情', '试听设置', '分析与快捷键', '浏览与保存']);
    final button = find.byKey(const ValueKey('editor-manual-refine-td'));
    await Scrollable.ensureVisible(t.element(button), alignment: .5);
    await t.pumpAndSettle();
    await t.tap(button);
    await t.pumpAndSettle();
    await checkSteps(t, ['放置端点', '精确微调', '试听设置', '套用建议', '快捷键与确认']);
    expect(notifier.state.markerSeconds, before);
    expect(notifier.state.dirty, dirty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();
  });
}
