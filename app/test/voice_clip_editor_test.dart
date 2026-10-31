import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_overview.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/widgets/time_input_field.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';

Future<void> open(
  WidgetTester tester,
  double width, {
  List<Map<String, dynamic>>? renders,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(
        body: VoiceClipEditor(
          asset: {'id': 'a', 'name': '语音素材', 'category': '导航', 'duration': 4.0},
          folders: const ['未分类', '导航', '导航/路线'],
          load: () async => {
            'path': 'source.wav',
            'duration': 4.0,
            'bins': List.filled(512, .5),
          },
          render: (edit) async {
            renders?.add(edit);
            var duration = 4.0;
            for (final op in edit['audio_edits'] as List) {
              if (op['kind'] == 'insert') duration += op['duration'] as double;
              if (op['kind'] == 'delete') {
                duration -= (op['end'] as double) - (op['start'] as double);
              }
            }
            if (duration <= 0) throw const FormatException('不能删除整段音频');
            return {
              'path': 'edited.wav',
              'duration': duration,
              'bins': List.filled(512, .5),
            };
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'saving retains non-destructive operations and the prepared waveform',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => VoiceClipEditor(
                      asset: const {'id': 'a', 'name': '素材', 'duration': 2.0},
                      folders: const ['未分类'],
                      load: () async => {
                        'path': 'source.wav',
                        'duration': 2.0,
                        'bins': List.filled(100, .5),
                      },
                      render: (edit) async => {
                        'path': 'prepared.wav',
                        'duration': 2.1,
                        'bins': List.filled(100, .5),
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('material-insert-silence'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('material-insert-silence')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RmButton, '保存素材'));
      await tester.pumpAndSettle();
      expect(saved!['audio_edits'], [
        {'kind': 'insert', 'at': 0.0, 'duration': .1},
      ]);
      expect(saved!['start'], 0);
      expect(saved!['end'], 2);
      expect(saved!['wave']['path'], 'prepared.wav');
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [1100.0, 720.0, 520.0]) {
    testWidgets('waveform material editor fits $width', (tester) async {
      await open(tester, width);
      expect(find.byKey(const ValueKey('voice-clip-waveform')), findsOneWidget);
      expect(find.byType(RmSelect<String>), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-clip-folder')), findsOneWidget);
      expect(find.byType(TimeInputField), findsNothing);
      expect(find.textContaining('左键定位播放'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-insert-silence')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'left click seeks, right drag selects and deletion can undo without rendering',
    (tester) async {
      final renders = <Map<String, dynamic>>[];
      await open(tester, 1100, renders: renders);
      final wave = find.byKey(const ValueKey('voice-clip-waveform'));
      final rect = tester.getRect(wave);
      await tester.tapAt(Offset(rect.left + rect.width / 4, rect.center.dy));
      await tester.pumpAndSettle();
      ManualFocusWaveform current() => tester.widget<ManualFocusWaveform>(wave);
      expect(current().playhead, closeTo(1, .02));
      expect(current().handles, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(current().playhead, closeTo(1, .02));
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width / 4, rect.center.dy),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.moveTo(Offset(rect.left + rect.width / 2, rect.center.dy));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current().selectionStart, closeTo(1, .02));
      expect(current().selectionEnd, closeTo(2, .02));
      await tester.tap(find.byKey(const ValueKey('material-delete-selection')));
      await tester.pumpAndSettle();
      expect(current().duration, closeTo(3, .02));
      expect(renders.single['audio_edits'], hasLength(1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(current().duration, 4);
      expect(renders, hasLength(1));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: rect.center,
          scrollDelta: const Offset(0, -240),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final overview = find.byKey(const ValueKey('voice-clip-overview'));
      var view = tester.widget<WaveformOverview>(overview);
      expect(view.windowEnd - view.windowStart, lessThan(4));
      await tester.drag(overview, const Offset(200, 0));
      await tester.pumpAndSettle();
      view = tester.widget<WaveformOverview>(overview);
      expect(view.windowStart, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'silence insertion defaults to 100ms and supports custom lengths',
    (tester) async {
      final renders = <Map<String, dynamic>>[];
      await open(tester, 1100, renders: renders);
      final insert = find.byKey(const ValueKey('material-insert-silence'));
      await tester.tap(insert);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform))
            .duration,
        closeTo(4.1, .00001),
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-silence-ms')),
        '250',
      );
      await tester.tap(insert);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform))
            .duration,
        closeTo(4.35, .00001),
      );
      await tester.enterText(
        find.byKey(const ValueKey('material-silence-ms')),
        'bad',
      );
      await tester.tap(insert);
      await tester.pumpAndSettle();
      expect(renders, hasLength(2));
      expect(find.textContaining('请输入大于 0'), findsOneWidget);
      expect(
        tester
            .widget<RmButton>(find.widgetWithText(RmButton, '保存素材'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
