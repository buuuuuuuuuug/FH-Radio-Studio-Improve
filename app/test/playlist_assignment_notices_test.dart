import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/assignment_radio_choice.dart';
import 'package:fh_radio_studio/widgets/batch_assignment_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'studio_v18_workflow_test.dart' as fixtures;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  void viewport(WidgetTester t, Size size) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
  }

  testWidgets(
    'batch action hugs right side and remains separate from selection controls',
    (t) async {
      viewport(t, const Size(1800, 1100));
      final c = await fixtures.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(const PlaylistScreen()),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('playlist-multiselect-toggle')));
      await t.pump();
      final row = t.getRect(
        find.byKey(const ValueKey('playlist-selection-actions')),
      );
      final assign = t.getRect(
        find.byKey(const ValueKey('playlist-batch-assign')),
      );
      final clear = t.getRect(find.widgetWithText(RmButton, '清空'));
      expect(assign.right, closeTo(row.right, .01));
      expect(clear.right, lessThan(assign.left));
      expect(t.takeException(), isNull);
    },
  );
  for (final size in [const Size(420, 650), const Size(900, 900)]) {
    testWidgets(
      'batch card choices, scene preview, keyboard and atomic capacity guard at $size',
      (t) async {
        viewport(t, size);
        ({String radio, String type, int limit})? result;
        await t.pumpWidget(
          helpers.app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result =
                      await showDialog<
                        ({String radio, String type, int limit})
                      >(
                        context: context,
                        builder: (_) => BatchAssignmentDialog(
                          radios: kRadios,
                          tracks: kCustomPool.take(2).toList(),
                          splitTypes: true,
                          initialType: 'FreeRoam',
                          info: (r, type) => BatchAssignmentInfo(
                            total: r.code == 'R1' && type == 'FreeRoam'
                                ? 34
                                : 2,
                            added: 2,
                            limit: 32,
                            replacesBuiltin: type == 'Event',
                          ),
                        ),
                      );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        );
        await t.tap(find.text('打开'));
        await t.pumpAndSettle();
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(
          find.byType(AssignmentRadioChoice),
          findsNWidgets(kRadios.length),
        );
        RmButton confirm() =>
            t.widget(find.byKey(const ValueKey('batch-assign-confirm')));
        expect(confirm().onPressed, isNull);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(find.byType(BatchAssignmentDialog), findsOneWidget);
        expect(result, isNull);
        await t.tap(find.byKey(const ValueKey('batch-type-Event')));
        await t.pump();
        expect(confirm().onPressed, isNotNull);
        expect(confirm().label, '切换并分配');
        await t.tap(find.byKey(const ValueKey('batch-type-FreeRoam')));
        await t.pump();
        expect(confirm().onPressed, isNull);
        await t.sendKeyEvent(LogicalKeyboardKey.numpad2);
        await t.pump();
        final selected = t
            .widgetList<AssignmentRadioChoice>(
              find.byType(AssignmentRadioChoice),
            )
            .singleWhere((r) => r.selected);
        expect(selected.radio.code, 'R2');
        expect(result, isNull);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(result, (radio: 'R2', type: 'Event', limit: 32));
        expect(t.takeException(), isNull);
      },
    );
  }
  for (final brightness in Brightness.values) {
    for (final width in [360.0, 900.0, 1800.0]) {
      testWidgets(
        'global notices wrap, keep actions and close at $brightness / $width',
        (t) async {
          viewport(t, Size(width, 900));
          final key = GlobalKey<ScaffoldMessengerState>();
          var action = false;
          await t.pumpWidget(
            MaterialApp(
              scaffoldMessengerKey: key,
              theme: buildAppTheme(
                brightness: brightness,
                accent: AppAccent.lime,
              ),
              home: const Scaffold(body: Text('播放列表')),
            ),
          );
          final message = List.filled(
            4,
            '保存失败：当前未开启电台扩容，请先开启电台扩容，或减少歌曲数量。',
          ).join();
          key.currentState!.showSnackBar(
            SnackBar(
              content: Text(message),
              action: SnackBarAction(
                label: '查看',
                onPressed: () => action = true,
              ),
            ),
          );
          await t.pumpAndSettle();
          final text = t.getRect(find.text(message));
          expect(text.left, greaterThanOrEqualTo(0));
          expect(text.right, lessThanOrEqualTo(width));
          final card = find.descendant(
            of: find.byType(SnackBar),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Material &&
                  w.shape is RoundedRectangleBorder &&
                  w.elevation == 8,
            ),
          );
          expect(card, findsOneWidget);
          expect(t.getSize(card).width, lessThanOrEqualTo(600));
          final theme = Theme.of(t.element(find.text('播放列表')));
          expect(
            theme.snackBarTheme.backgroundColor,
            theme.extension<RmTheme>()!.panel,
          );
          expect(
            theme.snackBarTheme.contentTextStyle!.color,
            theme.extension<RmTheme>()!.fg,
          );
          await t.tap(find.text('查看'));
          await t.pumpAndSettle();
          expect(action, isTrue);
          key.currentState!.showSnackBar(
            const SnackBar(content: Text('歌曲分配与顺序已保存，无需构建准备包。')),
          );
          await t.pumpAndSettle();
          expect(find.byIcon(Icons.close), findsOneWidget);
          await t.tap(find.byIcon(Icons.close));
          await t.pumpAndSettle();
          expect(find.text('歌曲分配与顺序已保存，无需构建准备包。'), findsNothing);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
