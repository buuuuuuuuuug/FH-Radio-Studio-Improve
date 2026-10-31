import 'dart:async';
import 'package:fh_radio_studio/core/audio_import_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/widgets/external_audio_drop_target.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:fh_radio_studio/screens/stingers.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_card.dart';
import 'package:fh_radio_studio/state/stinger_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'external_audio_drop_test.dart' as bridge;
import 'studio_v18_workflow_test.dart' as fixtures;
import 'stinger_staged_edit_test.dart' as stinger;
import 'voice_replacement_test.dart' as voice;
import 'voice_workbench_v2_test.dart' as data;

class _ImportStudio extends StudioController {
  _ImportStudio(super.prefs, StudioState initial, this.pending) {
    state = initial;
  }
  final Completer<String?> pending;
  List<String> received = [];
  @override
  Future<void> startupFullCheckOnce() async {}
  @override
  Future<String?> importMusicPaths(List<String> paths) async {
    received = paths;
    state = state.copyWith(busy: true, busyLabel: '导入自建歌曲');
    try {
      return await pending.future;
    } finally {
      state = state.copyWith(busy: false, busyLabel: null);
    }
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test('import failures show the named failure before decoder diagnostics', () {
    expect(
      audioImportErrorDetail(
        'FormatException: Note: Invalid MPEG header\n'
        'Note: Trying to resync\nerror: 无法读取素材时长：损坏音频.mp3',
      ),
      '无法读取素材时长：损坏音频.mp3',
    );
    expect(audioImportErrorDetail('目录不可读\n请检查权限'), '目录不可读\n请检查权限');
    expect(audioImportErrorDetail(''), isEmpty);
  });
  testWidgets(
    'Explorer hover moves between targets and clears on exit or an empty drop',
    (t) async {
      final imported = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: ExternalAudioDropTarget(
              label: '素材池导入',
              onDrop: (_) async => imported.add('pool'),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 260,
                  height: 70,
                  child: ExternalAudioDropTarget(
                    label: '替换当前语音',
                    onDrop: (_) async => imported.add('entry'),
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        await bridge.event(t, 'filesEntered', const Offset(30, 30), [
          'D:/音频.mp3',
        ]),
        isTrue,
      );
      await t.pump();
      expect(find.text('替换当前语音'), findsOneWidget);
      final hint = t.widget<Container>(
        find.byKey(const ValueKey('external-audio-drop-hint')),
      );
      expect(
        (hint.decoration as BoxDecoration).color!.computeLuminance(),
        greaterThan(0.65),
      );
      expect(find.text('素材池导入'), findsNothing);
      expect(imported, isEmpty);
      await bridge.event(t, 'filesMoved', const Offset(400, 300), [
        'D:/音频.mp3',
      ]);
      await t.pump();
      expect(find.text('素材池导入'), findsOneWidget);
      expect(find.text('替换当前语音'), findsNothing);
      await bridge.event(t, 'filesExited', Offset.zero, []);
      await t.pump();
      expect(
        find.byKey(const ValueKey('external-audio-drop-hint')),
        findsNothing,
      );
      await bridge.event(t, 'filesEntered', const Offset(30, 30), []);
      await t.pump();
      expect(
        find.byKey(const ValueKey('external-audio-drop-hint')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'rejected stinger preview shows a warning without hiding the editable pool',
    (t) async {
      t.view.physicalSize = const Size(1700, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final state = c.read(studioProvider);
      final catalog = stinger.catalog(state.targetLang)
        ..['preview_warnings'] = ['Voice：台呼音量过高'];
      c.read(stingerMemoryCacheProvider.notifier).state = {
        '${state.projectDir}|${state.gameDir}|${state.targetLang}|false':
            catalog,
      };
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: StingersScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.textContaining('部分素材预览未就绪', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Voice：台呼音量过高', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Voice'), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-Voice-1')), findsOneWidget);
      expect(find.text('尚未读取台呼'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  testWidgets(
    'stinger exit multiselect clears every selection and per-material deletion uses the draft',
    (t) async {
      t.view.physicalSize = const Size(1700, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final state = c.read(studioProvider);
      final catalog = stinger.catalog(state.targetLang);
      catalog['assets'] = [
        for (final id in ['a', 'b', 'c'])
          {
            'id': id,
            'name': '素材$id',
            'duration': 2.0,
            'edit': {...stinger.edit, 'asset_id': id},
          },
      ];
      catalog['draft']['asset_names'] = {
        for (final id in ['a', 'b', 'c']) id: '素材$id',
      };
      c.read(stingerMemoryCacheProvider.notifier).state = {
        '${state.projectDir}|${state.gameDir}|${state.targetLang}|false':
            catalog,
      };
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: StingersScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
      unawaited(c.read(featureToursProvider).showCurrent());
      await t.pumpAndSettle();
      for (final title in ['查看与编辑台呼', '查找与布局', '准备台呼素材', '按电台分配', '保存与构建']) {
        expect(find.text(title), findsOneWidget);
        if (title == '准备台呼素材') {
          final dynamic painter = t
              .widget<CustomPaint>(
                find.byKey(const ValueKey('feature-tour-highlight')),
              )
              .painter;
          final Rect rect = painter.rect;
          final pool = t.getRect(find.byKey(const ValueKey('stinger-pool')));
          expect(rect.left, closeTo(pool.left - 5, 1));
          expect(rect.right, closeTo(pool.right + 5, 1));
          expect(rect.height, closeTo(pool.height + 10, 1));
        }
        if (title == '按电台分配') {
          final dynamic painter = t
              .widget<CustomPaint>(
                find.byKey(const ValueKey('feature-tour-highlight')),
              )
              .painter;
          final Rect rect = painter.rect;
          final board = t.getRect(
            find.byKey(const ValueKey('stinger-radio-board')),
          );
          expect(rect.width, closeTo(board.width + 10, 1));
        }
        await t.tap(find.text(title == '保存与构建' ? '知道了' : '下一步'));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const ValueKey('stinger-pool-multiselect')));
      await t.pumpAndSettle();
      for (final id in ['a', 'b', 'c']) {
        await t.tap(find.text('素材$id'));
        await t.pumpAndSettle();
      }
      expect(find.text('已选 3'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stinger-batch-assign')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('stinger-pool-multiselect')));
      await t.pumpAndSettle();
      expect(find.textContaining('已选'), findsNothing);
      expect(find.byKey(const ValueKey('stinger-batch-assign')), findsNothing);
      expect(
        t
            .widgetList<StingerCard>(find.byType(StingerCard))
            .where((c) => c.selected),
        isEmpty,
      );
      await t.tap(find.byKey(const ValueKey('remove-素材b-2')));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(RmButton, '移除素材'));
      await t.pumpAndSettle();
      expect(find.text('素材b'), findsNothing);
      expect(find.text('素材a'), findsOneWidget);
      expect(c.read(stingerDraftProvider.notifier).dirty, isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'voice import shows conversion feedback, blocks a second drop and reports completion',
    (t) async {
      final pending = Completer<Map<String, dynamic>>();
      final snapshot = data.scan();
      var imports = 0;
      await voice.open(
        t,
        const Size(1800, 950),
        [],
        responder: (a, o) async {
          if (a == 'scan') return snapshot;
          if (a == 'import') {
            imports++;
            return pending.future;
          }
          return {};
        },
      );
      final pool = find.byKey(const ValueKey('voice-asset-filter'));
      final point = t.getCenter(pool);
      final dropped = bridge.drop(t, point, ['D:/素材/测试.mp3']);
      await t.pump();
      expect(
        find.byKey(const ValueKey('audio-import-progress')),
        findsOneWidget,
      );
      expect(find.textContaining('转换试听副本'), findsOneWidget);
      expect(await bridge.drop(t, point, ['D:/素材/重复.wav']), isFalse);
      pending.complete({
        'plan': snapshot['plan'],
        'asset_ids': ['x'],
      });
      await dropped;
      await t.pumpAndSettle();
      expect(imports, 1);
      expect(find.byKey(const ValueKey('audio-import-progress')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('语音导入完成'),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'failed voice import names the failure and leaves replacements untouched',
    (t) async {
      await voice.open(
        t,
        const Size(1800, 950),
        [],
        responder: (a, o) async {
          if (a == 'scan') return data.scan();
          if (a == 'import') throw const FormatException('无法读取损坏文件 bad.mp3');
          return {};
        },
      );
      await bridge.drop(
        t,
        t.getCenter(find.byKey(const ValueKey('voice-asset-filter'))),
        ['D:/bad.mp3'],
      );
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('bad.mp3'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('0 条替换'), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-import-progress')), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'song page accepts Explorer files and reuses the song conversion gate and result toast',
    (t) async {
      t.view.physicalSize = const Size(1700, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final parent = await fixtures.fixture();
      final prefs = await SharedPreferences.getInstance();
      final pending = Completer<String?>();
      final initial = parent.read(studioProvider);
      late _ImportStudio controller;
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith(
            (ref) => controller = _ImportStudio(prefs, initial, pending),
          ),
        ],
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: CustomPoolScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
      final dropped = bridge.drop(t, const Offset(900, 300), ['D:/我的歌.mp3']);
      await t.pump();
      expect(controller.received, ['D:/我的歌.mp3']);
      expect(
        find.byKey(const ValueKey('custom-pool-import-gate')),
        findsOneWidget,
      );
      expect(find.textContaining('48 kHz'), findsOneWidget);
      pending.complete('已导入 1 首歌曲。');
      await dropped;
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('已导入 1 首歌曲。'),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
