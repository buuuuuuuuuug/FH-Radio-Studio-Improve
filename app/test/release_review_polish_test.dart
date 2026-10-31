import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/pool_selection_actions.dart';
import 'studio_v18_workflow_test.dart' as fixtures;
import 'voice_workbench_v2_test.dart' as voice;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [240.0, 280.0, 320.0]) {
    testWidgets('pool batch assignment stays on one row at $width', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: PoolSelectionActions(
                  count: 10,
                  onSelectAll: () {},
                  onClear: () {},
                  actions: [
                    RmButton(
                      label: '分配至电台',
                      size: RmButtonSize.sm,
                      horizontalPadding: 8,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final assign = t.getCenter(find.text('分配至电台')).dy;
      expect(t.getCenter(find.text('全选')).dy, closeTo(assign, 1));
      expect(t.getCenter(find.text('清空')).dy, closeTo(assign, 1));
      expect(t.getCenter(find.text('已选 10')).dy, closeTo(assign, 1));
      expect(t.takeException(), isNull);
    });
  }
  for (final material in [false, true]) {
    testWidgets(
      'Escape exits ${material ? 'material' : 'entry'} selection after outside focus',
      (t) async {
        t.view.physicalSize = const Size(1800, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final c = await fixtures.fixture();
        final outside = FocusNode();
        addTearDown(outside.dispose);
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
                      width: 120,
                      child: TextField(
                        key: const ValueKey('outside-field'),
                        focusNode: outside,
                      ),
                    ),
                    Expanded(
                      child: VoiceReplacementScreen(
                        request: (a, o) async =>
                            a == 'scan' ? voice.scan() : {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        if (material) {
          await t.tap(find.text('路线'));
          await t.pumpAndSettle();
        }
        for (final searchFocused in [false, true]) {
          outside.requestFocus();
          await t.pump();
          expect(outside.hasFocus, isTrue);
          await t.tap(
            find.byKey(
              ValueKey(
                material ? 'voice-pool-multiselect' : 'voice-export-text',
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(outside.hasFocus, isFalse);
          await t.tap(
            find.byKey(
              ValueKey(
                material
                    ? 'voice-material-select-all'
                    : 'voice-toggle-all-entries',
              ),
            ),
          );
          await t.pumpAndSettle();
          if (searchFocused) {
            await t.tap(
              find.descendant(
                of: find.byKey(const ValueKey('voice-entry-filter')),
                matching: find.byType(TextField),
              ),
            );
            await t.pump();
          }
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pumpAndSettle();
          expect(find.text('退出多选'), findsNothing);
          expect(
            find.byKey(const ValueKey('voice-toggle-all-entries')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('voice-material-select-all')),
            findsNothing,
          );
          expect(
            t
                .widgetList<TrackCard>(find.byType(TrackCard))
                .any((card) => card.selectionMode || card.selected),
            isFalse,
          );
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
      },
    );
  }
}
