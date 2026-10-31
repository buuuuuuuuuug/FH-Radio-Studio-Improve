import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/widgets/rm_tooltip.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final scale in [1.0, 1.25, 2.0]) {
    testWidgets('short CJK tooltip stays on one line at scale $scale', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: Center(
              child: RmTooltip(
                message: '试听',
                child: SizedBox(key: ValueKey('anchor'), width: 26, height: 26),
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('anchor'))),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final tip = find.text('试听', findRichText: true);
      expect(tip, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(tip);
      expect(
        paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 2),
            )
            .length,
        1,
      );
      expect(tester.getSize(tip).width, greaterThanOrEqualTo(25 * scale));
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
