import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'external_audio_drop_test.dart' as bridge;
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as fixtures;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('external files import and assign in the returned file order', (
    tester,
  ) async {
    final calls = <String>[];
    final data = fixtures.scan();
    await base.open(
      tester,
      const Size(1800, 900),
      calls,
      responder: (action, options) async {
        if (action == 'scan') return data;
        if (action == 'import') {
          expect(options['paths'], ['D:/素材/second.wav', 'D:/素材/first.wav']);
          final plan = Map<String, dynamic>.from(data['plan'] as Map);
          plan['assets'] = [
            ...plan['assets'] as List,
            {'id': 'z', 'name': 'First', 'category': 'Alice', 'duration': 1.0},
            {'id': 'w', 'name': 'Second', 'category': 'Alice', 'duration': 1.0},
          ];
          return {
            'plan': plan,
            'asset_ids': ['w', 'z'],
          };
        }
        return {};
      },
    );
    final row0 = find.byKey(const ValueKey('voice-entry-0'));
    expect(
      await bridge.drop(
        tester,
        tester.getCenter(find.byKey(const ValueKey('voice-replacement-0'))),
        ['D:/素材/second.wav', 'D:/素材/first.wav'],
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row0, matching: find.text('Second')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice-entry-1')),
        matching: find.text('First'),
      ),
      findsOneWidget,
    );
    expect(find.text('Alice | 4'), findsOneWidget);
    expect(calls, ['scan', 'import']);
    expect(tester.takeException(), isNull);
  });
}
