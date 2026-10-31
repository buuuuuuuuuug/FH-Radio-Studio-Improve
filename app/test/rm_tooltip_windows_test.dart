import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/widgets/rm_tooltip.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets(
    'Windows scrolling tooltips keep stable semantics across hover and disposal',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 15; i++)
                  RmTooltip(
                    message: '提示 $i',
                    child: SizedBox(
                      key: ValueKey('row-$i'),
                      height: 35,
                      child: Text('row $i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (var i = 0; i < 8; i++) {
        await mouse.moveTo(tester.getCenter(find.byKey(ValueKey('row-$i'))));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('提示 $i', findRichText: true), findsOneWidget);
        final tip = find
            .ancestor(
              of: find.text('提示 $i', findRichText: true),
              matching: find.byType(Container),
            )
            .first;
        final decoration =
            tester.widget<Container>(tip).decoration as BoxDecoration;
        final theme = Theme.of(
          tester.element(find.byKey(ValueKey('row-$i'))),
        ).tooltipTheme;
        expect(decoration, theme.decoration);
      }
      expect(find.byType(OverlayPortal), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
