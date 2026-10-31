import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_editor.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/voices/voice_text_export_dialog.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'voice_replacement_test.dart' as page;
import 'voice_workbench_v2_test.dart' as data;
import 'voice_clip_editor_test.dart' as clip;
import 'studio_v18_workflow_test.dart' as fixtures;

class _GuideStreams extends Fake implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _GuidePlayer extends Fake implements Player {
  @override
  PlayerState get state => const PlayerState();
  @override
  PlayerStream get stream => _GuideStreams();
  @override
  Future<void> pause() async {}
}

Future<void> completeGuide(WidgetTester t, List<String> titles) async {
  for (final title in titles) {
    expect(find.text(title), findsWidgets);
    expect(
      find.byKey(const ValueKey('feature-tour-highlight')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
    await t.tap(find.text(title == titles.last ? '知道了' : '下一步'));
    await t.pumpAndSettle();
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test('export filenames identify the resource for every format', () {
    for (final format in ['txt', 'csv', 'xlsx']) {
      expect(
        VoiceTextExportDialog.fileName(
          r'C:\game\VO_Test_JP.assets.bank',
          format,
        ),
        'VO_Test_JP.assets.bank_语音文本导出.$format',
      );
    }
  });
  testWidgets(
    'both Overview languages refresh the current and cached voice page',
    (t) async {
      final c = await fixtures.fixture();
      final requests = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> request(
        String action,
        Map<String, dynamic> options,
      ) async {
        if (action != 'scan') return {};
        final input = Map<String, dynamic>.from(options['input']);
        requests.add(input);
        final snapshot = data.scan();
        for (final catalog in (snapshot['catalogs'] as Map).values) {
          catalog['entries'][0]['content'] = 'Voice ${input['voice_language']}';
          catalog['entries'][0]['translation'] =
              'Display ${input['display_language']}';
        }
        return snapshot;
      }

      await page.open(
        t,
        const Size(1700, 950),
        [],
        container: c,
        responder: request,
      );
      final controller = c.read(studioProvider.notifier);
      controller.setSourceLang('DE');
      controller.setTargetLang('EN');
      await t.pumpAndSettle();
      expect(requests.last['voice_language'], 'EN');
      expect(requests.last['display_language'], 'DE');
      expect(find.text('Voice EN'), findsOneWidget);
      expect(find.text('Display DE'), findsOneWidget);
      expect(find.text('中文字幕'), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      controller.setSourceLang('JP');
      await page.open(
        t,
        const Size(1700, 950),
        [],
        container: c,
        responder: request,
      );
      expect(requests.last['display_language'], 'JP');
      expect(find.text('Display JP'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  for (final width in [1500.0, 850.0]) {
    testWidgets('voice guide targets real controls at $width and can replay', (
      t,
    ) async {
      final c = await fixtures.fixture();
      await page.open(
        t,
        Size(width, 950),
        [],
        container: c,
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      unawaited(c.read(featureToursProvider).showCurrent());
      await t.pumpAndSettle();
      final titles = ['选择音频资源', '对照原音与替换', '整理替换素材', '查找与批量操作', '保存、构建与写入'];
      for (final (index, title) in titles.indexed) {
        expect(find.text(title), findsWidgets);
        expect(find.text('功能介绍  ${index + 1} / 5'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsOneWidget,
        );
        if (title == '对照原音与替换') {
          final dynamic painter = t
              .widget<CustomPaint>(
                find.byKey(const ValueKey('feature-tour-highlight')),
              )
              .painter;
          final Rect highlighted = painter.rect;
          final viewport = t.getRect(
            find.byKey(const ValueKey('voice-entry-viewport')),
          );
          expect(highlighted.right, lessThanOrEqualTo(viewport.right + 20));
          expect(highlighted.left, greaterThanOrEqualTo(viewport.left - 6));
        }
        if (title == '查找与批量操作' || title == '保存、构建与写入') {
          final dynamic painter = t
              .widget<CustomPaint>(
                find.byKey(const ValueKey('feature-tour-highlight')),
              )
              .painter;
          final Rect highlighted = painter.rect;
          final tools = t.getRect(
            find.byKey(const ValueKey('voice-workbench-tools')),
          );
          final search = t.getRect(
            find.byKey(const ValueKey('voice-workbench-search')),
          );
          final workflow = t.getRect(
            find.byKey(const ValueKey('voice-workflow-actions')),
          );
          if (title == '查找与批量操作') {
            expect(highlighted.left, closeTo(tools.left - 5, 1));
            expect(highlighted.right, closeTo(tools.right + 5, 1));
            expect(highlighted.top, closeTo(tools.top - 5, 1));
            expect(highlighted.bottom, closeTo(search.bottom + 5, 1));
            expect(highlighted.overlaps(workflow), isFalse);
          } else {
            expect(highlighted.left, closeTo(workflow.left - 5, 1));
            expect(highlighted.right, closeTo(workflow.right + 5, 1));
            expect(highlighted.top, closeTo(workflow.top - 5, 1));
            expect(highlighted.bottom, closeTo(workflow.bottom + 5, 1));
            expect(highlighted.overlaps(tools), isFalse);
          }
        }
        expect(t.takeException(), isNull);
        await t.tap(find.text(title == titles.last ? '知道了' : '下一步'));
        await t.pumpAndSettle();
      }
      unawaited(c.read(featureToursProvider).showCurrent());
      await t.pumpAndSettle();
      expect(find.text('选择音频资源'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
  for (final kind in ['silence', 'delete']) {
    for (final position in [.25, 3.8]) {
      testWidgets(
        '$kind preserves the cursor at $position or clamps to the new end',
        (t) async {
          await clip.open(t, 1200);
          ManualFocusWaveform wave() =>
              t.widget(find.byType(ManualFocusWaveform));
          wave().onSeek!(position);
          await t.pump();
          wave().onSelection!(1, 2);
          await t.pump();
          await t.tap(
            find.byKey(
              ValueKey(
                kind == 'silence'
                    ? 'material-silence-selection'
                    : 'material-delete-selection',
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(
            wave().playhead,
            kind == 'delete' && position > 3 ? 3 : position,
          );
          expect(wave().duration, kind == 'delete' ? 3 : 4);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  for (final width in [1400.0, 740.0]) {
    for (final metadata in [true, false]) {
      testWidgets(
        'voice editor guide matches ${metadata ? 'material' : 'replacement'} controls at $width',
        (t) async {
          final c = await fixtures.fixture();
          t.view.physicalSize = Size(width, 1000);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: MaterialApp(
                theme: buildAppTheme(
                  brightness: Brightness.light,
                  accent: AppAccent.lime,
                ),
                home: VoiceClipEditor(
                  featureTour: true,
                  metadata: metadata,
                  asset: const {'id': 'a', 'name': '测试语音', 'duration': 4.0},
                  folders: const ['未分类'],
                  load: () async => {
                    'path': 'source.wav',
                    'duration': 4.0,
                    'bins': List.filled(512, .5),
                  },
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          unawaited(c.read(featureToursProvider).showCurrent());
          await t.pumpAndSettle();
          await completeGuide(t, [
            '定位与选区',
            '试听与撤销',
            '简易音频编辑',
            '素材信息与音量',
            if (!metadata) '替换后的时长',
          ]);
        },
      );
    }
    testWidgets(
      'stinger editor guide targets timing, seam settings and footer at $width',
      (t) async {
        final c = await fixtures.fixture();
        t.view.physicalSize = Size(width, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final asset = <String, dynamic>{
          'id': 'a',
          'name': '测试台呼',
          'duration': 12.0,
          'source_preview': {
            'path': 'source.wav',
            'duration': 12.0,
            'bins': List.filled(512, .5),
          },
        };
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: buildAppTheme(
                brightness: Brightness.light,
                accent: AppAccent.lime,
              ),
              home: StingerEditor(
                featureTour: true,
                asset: asset,
                assets: [asset],
                songs: const [
                  {'path': 'before.wav', 'name': '上一首'},
                  {'path': 'after.wav', 'name': '下一首'},
                ],
                player: _GuidePlayer(),
                preferredWidth: 1080,
                usedCount: 0,
                play: (audio, {start, end, gain = 0}) async {},
                call: (action, input) async => {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        unawaited(c.read(featureToursProvider).showCurrent());
        await t.pumpAndSettle();
        await completeGuide(t, ['台呼波形', '播放与试听', '时间点', '台呼设置']);
      },
    );
  }
  testWidgets(
    'leaving a page during an editor tour closes both and permits a new guide',
    (t) async {
      final c = await fixtures.fixture();
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      t.view.physicalSize = const Size(1400, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: TextButton(
                      onPressed: () => visible.value = !visible.value,
                      child: const Text('切换页面'),
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: visible,
                      builder: (_, value, _) => value
                          ? AudioEditorHost(
                              child: Builder(
                                builder: (ctx) => TextButton(
                                  onPressed: () => showAudioEditorDialog<void>(
                                    context: ctx,
                                    builder: (_) => VoiceClipEditor(
                                      featureTour: true,
                                      asset: const {
                                        'id': 'a',
                                        'name': '测试语音',
                                        'duration': 4.0,
                                      },
                                      folders: const [],
                                      load: () async => {
                                        'path': 'source.wav',
                                        'duration': 4.0,
                                        'bins': List.filled(512, .5),
                                      },
                                    ),
                                  ),
                                  child: const Text('打开素材'),
                                ),
                              ),
                            )
                          : const Text('其他页面'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 2; i++) {
        await t.tap(find.text('打开素材'));
        await t.pumpAndSettle();
        unawaited(c.read(featureToursProvider).showCurrent());
        await t.pumpAndSettle();
        expect(find.text('定位与选区'), findsOneWidget);
        await t.tap(find.text('切换页面'));
        await t.pumpAndSettle();
        expect(find.byType(VoiceClipEditor), findsNothing);
        expect(
          find.byKey(const ValueKey('feature-tour-highlight')),
          findsNothing,
        );
        expect(t.takeException(), isNull);
        await t.tap(find.text('切换页面'));
        await t.pumpAndSettle();
      }
    },
  );
}
