import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'studio_v18_workflow_test.dart' as fixtures;

Map<String, dynamic> plan() => {
  'banks': {
    'b': {'replacements': <String, dynamic>{}},
  },
  'assets': [
    {'id': 'a', 'name': '测试语音', 'duration': 2.0, 'category': '播报'},
  ],
};
Map<String, dynamic> prepared() => {
  'plan': plan(),
  'bank': {
    'id': 'b',
    'name': 'VO_Test.assets.bank',
    'relative_path': 'media/audio/FMODBanks/VO_Test.assets.bank',
    'sha256': 'test',
    'supported': true,
  },
  'entries': [
    for (var i = 0; i < 7; i++)
      {
        'index': i,
        'name': '条目 ${i + 1}',
        'duration': 1.5,
        'channels': 1,
        'frequency': 48000,
      },
  ],
};

Future<void> open(
  WidgetTester tester,
  Size size,
  List<String> calls, {
  VoiceRequest? responder,
  ProviderContainer? container,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scope = container ?? await fixtures.fixture();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: scope,
      child: MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: VoiceReplacementScreen(
            request: (action, options) async {
              calls.add(action);
              if (responder != null) return responder(action, options);
              if (action == 'scan') {
                return {
                  'files': [
                    {
                      'name': 'VO_Test.assets.bank',
                      'relative_path':
                          'media/audio/FMODBanks/VO_Test.assets.bank',
                      'path':
                          'D:/Game/media/audio/FMODBanks/VO_Test.assets.bank',
                      'category': '活动与播报',
                    },
                  ],
                  'plan': plan(),
                };
              }
              if (action == 'prepare') return prepared();
              if (action == 'inspect') {
                return {
                  'count': 7,
                  'source_bytes': 1048576,
                  'decoded_bytes': 2097152,
                  'total_bytes': 3145728,
                };
              }
              if (action == 'decode-all') {
                return {'paths': <String, dynamic>{}, 'complete': true};
              }
              return {'saved': true};
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [1600.0, 1150.0, 990.0, 720.0]) {
    testWidgets('voice three-column layout fits $width', (tester) async {
      final calls = <String>[];
      await open(tester, Size(width, 850), calls);
      expect(find.text('音频资源'), findsOneWidget);
      expect(find.text('音频替换'), findsOneWidget);
      expect(find.text('素材池'), findsOneWidget);
      expect(calls, ['scan']);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'preparation requires confirmation and replacement can be undone',
    (tester) async {
      final calls = <String>[];
      await open(tester, const Size(1280, 900), calls);
      await tester.tap(find.text('VO_Test.assets.bank'));
      await tester.pumpAndSettle();
      expect(calls, ['scan']);
      await tester.tap(find.byKey(const ValueKey('voice-prepare')));
      await tester.pumpAndSettle();
      expect(calls, ['scan', 'inspect']);
      expect(find.textContaining('预计 7 个 WAV'), findsOneWidget);
      await tester.tap(find.widgetWithText(RmButton, '确认解析'));
      await tester.pumpAndSettle();
      expect(calls, ['scan', 'inspect', 'prepare', 'decode-all']);
      await tester.tap(find.text('测试语音'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.textContaining('0 条替换'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('测试语音')),
      );
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('voice-entry-0'))),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条替换'), findsOneWidget);
      await tester.tap(find.widgetWithText(RmButton, '撤销'));
      await tester.pumpAndSettle();
      expect(find.textContaining('0 条替换'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
