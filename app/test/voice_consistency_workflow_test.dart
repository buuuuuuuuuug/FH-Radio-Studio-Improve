import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_chip.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'content copies only with Ctrl click and uses the bottom snackbar',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add(call.arguments['text']);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await base.open(
        tester,
        const Size(1800, 950),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await tester.tap(find.byKey(const ValueKey('voice-copy-content-0')));
      expect(copied, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('voice-copy-content-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-copy-translation-0')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(copied, ['日本語 0', '中文 0']);
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-export-text')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voice-extract-assets')),
        findsOneWidget,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('voice-copy-content-1')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(copied.length, 2);
      expect(
        find.byKey(const ValueKey('voice-extract-assets')),
        findsOneWidget,
      );
      expect(find.text('已选 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'original audio selection extracts only chosen entries to the shared material pool',
    (tester) async {
      Map<String, dynamic>? request;
      final snapshot = data.scan();
      await base.open(
        tester,
        const Size(1800, 950),
        [],
        responder: (a, o) async {
          if (a == 'scan') return snapshot;
          if (a == 'extract-assets') {
            request = Map<String, dynamic>.from(o['input']);
            final plan = data.scan()['plan'];
            plan['assets'] = <dynamic>[
              ...(plan['assets'] as List),
              {
                'id': 'original0',
                'name': '原音频零',
                'category': '原音频',
                'duration': 2.0,
              },
              {
                'id': 'original2',
                'name': '原音频二',
                'category': '原音频',
                'duration': 2.0,
              },
            ];
            return {
              'plan': plan,
              'asset_ids': ['original0', 'original2'],
              'count': 2,
              'added': 2,
              'reused': 0,
            };
          }
          return {};
        },
      );
      await tester.tap(find.byKey(const ValueKey('voice-export-text')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-entry-0')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('voice-entry-2')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-extract-assets')));
      await tester.pumpAndSettle();
      expect(find.text('2 条原音频 · 保留完整时长'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-extract-confirm')));
      await tester.pumpAndSettle();
      expect(request!['indices'], [0, 2]);
      expect(request!['category'], '原音频');
      expect(find.text('原音频零'), findsOneWidget);
      expect(find.text('原音频二'), findsOneWidget);
      final cards = tester
          .widgetList<TrackCard>(find.byType(TrackCard))
          .where((c) => c.title.startsWith('原音频'))
          .toList();
      expect(cards.length, 2);
      expect(cards.every((c) => c.selectionMode && c.selected), isTrue);
      expect(find.byKey(const ValueKey('voice-material-move')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material multi-select uses playlist cards, checkboxes and clear/escape behavior',
    (tester) async {
      await base.open(
        tester,
        const Size(1600, 950),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await tester.tap(find.text('路线'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-pool-multiselect')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('素材一'));
      await tester.tap(find.text('素材二'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TrackCard>(find.byType(TrackCard))
            .every((c) => c.selectionMode && c.selected),
        isTrue,
      );
      expect(find.text('已选 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TrackCard>(find.byType(TrackCard))
            .any((c) => c.selectionMode || c.selected),
        isFalse,
      );
      expect(find.text('多选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'status and toolbar keep the original accent chip and button backgrounds',
    (tester) async {
      await base.open(
        tester,
        const Size(2200, 950),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      final chip = tester.widget<RmChip>(
        find.byKey(const ValueKey('voice-resource-status')),
      );
      expect(chip.variant, RmChipVariant.accent);
      expect(chip.showDot, isTrue);
      final names = ['撤销', '重做', '恢复原音', '打开音频目录', '删除解析', '多选导出'];
      final buttons = [
        for (final name in names) find.widgetWithText(RmButton, name),
      ];
      for (final finder in buttons) {
        expect(
          tester.widget<RmButton>(finder).variant,
          RmButtonVariant.defaultBtn,
        );
        expect(
          tester.getCenter(finder).dy,
          closeTo(tester.getCenter(buttons.first).dy, .1),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
