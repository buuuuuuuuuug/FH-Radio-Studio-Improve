import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/voices/voice_text_export_dialog.dart';
import 'package:fh_radio_studio/state/editor_shortcuts.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'voice_clip_editor_test.dart' as clip;
import 'voice_replacement_test.dart' as page;
import 'voice_workbench_v2_test.dart' as data;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'previous redo default migrates independently of customized playback',
    () async {
      SharedPreferences.setMockInitialValues({
        'editor.shortcuts.version': 9,
        'editor.shortcuts.v1': jsonEncode({
          'redo': const EditorChord(
            LogicalKeyboardKey.keyZ,
            ctrl: true,
            shift: true,
          ).toJson(),
          'play': const EditorChord(
            LogicalKeyboardKey.keyP,
            ctrl: true,
          ).toJson(),
        }),
      });
      final controller = EditorShortcutController(
        await SharedPreferences.getInstance(),
      );
      expect(controller.state[EditorAction.redo]!.label, 'Ctrl + Y');
      expect(controller.state[EditorAction.play]!.label, 'Ctrl + P');
      controller.dispose();
    },
  );
  testWidgets(
    'material metadata stays beside the waveform and edit tools sit below playback',
    (t) async {
      await clip.open(t, 1200);
      final wave = find.byKey(const ValueKey('voice-clip-waveform'));
      final settings = find.byKey(const ValueKey('material-edit-actions'));
      expect(t.getRect(settings).top, greaterThan(t.getRect(wave).bottom));
      expect(
        t.getRect(find.byKey(const ValueKey('voice-clip-folder'))).left,
        greaterThan(t.getRect(wave).right),
      );
      expect(find.text('显示完整音频'), findsNothing);
      await t.tap(find.byKey(const ValueKey('material-insert-silence')));
      await t.pumpAndSettle();
      expect(t.widget<ManualFocusWaveform>(wave).duration, closeTo(4.1, .0001));
      await helpers.keyCombo(t, LogicalKeyboardKey.keyZ, ctrl: true);
      expect(t.widget<ManualFocusWaveform>(wave).duration, 4);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyY, ctrl: true);
      expect(t.widget<ManualFocusWaveform>(wave).duration, closeTo(4.1, .0001));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'clicking a modification mark jumps in one frame without animation',
    (t) async {
      final snapshot = data.scan();
      final catalog = snapshot['active'] as Map;
      catalog['entries'] = [
        for (var i = 0; i < 600; i++)
          {'index': i, 'name': '语音 $i', 'duration': 2.0},
      ];
      snapshot['catalogs']['A'] = catalog;
      snapshot['plan']['banks']['A']['replacements'] = {
        '300': {'asset_id': 'x', 'start': 0, 'end': 2, 'gain_db': 0},
      };
      await page.open(
        t,
        const Size(1700, 950),
        [],
        responder: (a, o) async => a == 'scan' ? snapshot : {},
      );
      final rail = t.getRect(find.byKey(const ValueKey('voice-change-map')));
      await t.tapAt(
        Offset(rail.left + 2, rail.top + rail.height * 300.5 / 600),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('voice-entry-300')), findsOneWidget);
      final y = t.getCenter(find.byKey(const ValueKey('voice-entry-300'))).dy;
      expect(y, closeTo(rail.center.dy, 25));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.getCenter(find.byKey(const ValueKey('voice-entry-300'))).dy, y);
      expect(t.takeException(), isNull);
    },
  );
  for (final width in [1100.0, 700.0]) {
    testWidgets('live export offers XLSX and fits a $width window', (t) async {
      t.view.physicalSize = Size(width, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var loads = 0;
      await t.pumpWidget(
        helpers.app(
          VoiceTextExportDialog(
            name: '测试 JP.bank',
            count: 2,
            load: () async {
              loads++;
              return {
                'headers': ['序号', '条目', '语音语言', '显示语言', '时长（秒）'],
                'rows': [
                  ['1', '0001', '日本語', '请左转', '2.000'],
                  ['2', '0002', '', '', '1.000'],
                ],
              };
            },
            xlsx: (_, _) async => [],
            tablePreview: (_, headers, rows) =>
                Text(rows.map((r) => r.join('|')).join('\n')),
            notify: (_) {},
            onExported: () {},
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('实时预览'), findsOneWidget);
      expect(find.text('生成预览'), findsNothing);
      await t.tap(find.text('仅包含已找到文本的条目'));
      await t.pumpAndSettle();
      expect(find.text('1 条'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('voice-export-format')));
      await t.pumpAndSettle();
      await t.tap(find.text('工作簿 XLSX').last);
      await t.pumpAndSettle();
      expect(find.widgetWithText(RmButton, '导出 XLSX'), findsOneWidget);
      expect(loads, 1);
      expect(t.takeException(), isNull);
    });
  }
}
