import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'new folder names edit inline and Escape or outside click cancels without renaming',
    (tester) async {
      final snapshot = data.scan();
      final actions = <String>[];
      await base.open(
        tester,
        const Size(1600, 900),
        [],
        responder: (action, options) async {
          if (action == 'scan') return snapshot;
          if (action == 'folders') {
            final request = Map<String, dynamic>.from(options['input']);
            actions.add(request['action']);
            if (request['action'] == 'create') {
              (snapshot['plan']['folders'] as List).add(request['name']);
            }
            return {'plan': snapshot['plan']};
          }
          return {};
        },
      );
      await tester.tap(find.byKey(const ValueKey('voice-new-folder')));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('voice-rename-folder-新建文件夹'));
      expect(first, findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.getSize(first).height, lessThanOrEqualTo(24));
      await tester.enterText(first, '取消的名称');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(first, findsNothing);
      expect(actions, ['create']);
      await tester.tap(find.byKey(const ValueKey('voice-new-folder')));
      await tester.pumpAndSettle();
      final second = find.byKey(
        const ValueKey('voice-rename-folder-新建文件夹 (2)'),
      );
      expect(second, findsOneWidget);
      await tester.enterText(second, '另一个取消的名称');
      await tester.tap(find.text('音频资源'));
      await tester.pumpAndSettle();
      expect(second, findsNothing);
      expect(actions, ['create', 'create']);
      expect(tester.takeException(), isNull);
    },
  );
}
