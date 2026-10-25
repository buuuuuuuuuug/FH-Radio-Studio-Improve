import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/widgets/assignment_radio_choice.dart';
import 'package:fh_radio_studio/widgets/assignment_shortcuts.dart';
import 'package:fh_radio_studio/widgets/batch_assignment_dialog.dart';
import 'package:fh_radio_studio/widgets/quick_assign_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'studio_v18_workflow_test.dart' as fixtures;
import 'studio_v21_workflow_test.dart' as helpers;

void viewport(WidgetTester t) {
  t.view.physicalSize = const Size(1000, 1050);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Future<void> controlKey(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(key);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'quick choices distinguish Event digits, FreeRoam Ctrl digits and mouse scene',
    (t) async {
      viewport(t);
      final c = await fixtures.fixture();
      final notifier = c.read(playlistProvider.notifier);
      notifier.setSplitPlaylistTypes(true);
      notifier.setMode(PlaylistMode.freeroam);
      final track = c.read(playlistProvider).pool.first;
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showQuickAssign(context, track),
                child: const Text('打开分配'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await t.tap(find.text('打开分配'));
        await t.pumpAndSettle();
      }

      PlaylistPlan plan() => c.read(effectivePlaylistPlanProvider);
      await open();
      expect(
        t
            .widget<RmButton>(find.byKey(const ValueKey('quick-type-Event')))
            .variant,
        RmButtonVariant.primary,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.digit2);
      await t.pumpAndSettle();
      expect(plan().assignmentsForRadio('R2', 'Event'), hasLength(1));
      expect(plan().assignmentsForRadio('R2', 'FreeRoam'), isEmpty);
      await open();
      await controlKey(t, LogicalKeyboardKey.numpad3);
      expect(plan().assignmentsForRadio('R3', 'FreeRoam'), hasLength(1));
      expect(plan().assignmentsForRadio('R3', 'Event'), isEmpty);
      await open();
      await t.tap(find.byKey(const ValueKey('quick-type-FreeRoam')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('quick-assign-R4')));
      await t.pumpAndSettle();
      expect(plan().assignmentsForRadio('R4', 'FreeRoam'), hasLength(1));
      expect(plan().assignmentsForRadio('R4', 'Event'), isEmpty);
      final before = plan().encodeForCli();
      await open();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byType(QuickAssignDialog), findsOneWidget);
      expect(plan().encodeForCli(), before);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(QuickAssignDialog), findsNothing);
      expect(plan().encodeForCli(), before);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'unified quick assignment accepts Ctrl numpad and writes both scenes',
    (t) async {
      viewport(t);
      final c = await fixtures.fixture();
      final track = c.read(playlistProvider).pool.first;
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showQuickAssign(context, track),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('quick-type-Event')), findsNothing);
      await controlKey(t, LogicalKeyboardKey.numpad8);
      final plan = c.read(effectivePlaylistPlanProvider);
      expect(plan.assignmentsForRadio('R8', 'FreeRoam'), hasLength(1));
      expect(plan.assignmentsForRadio('R8', 'Event'), hasLength(1));
      expect(plan.hasSplitPlaylistDifferences, isFalse);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'batch digits select a scene and station but keep Enter confirmation',
    (t) async {
      viewport(t);
      ({String radio, String type, int limit})? result;
      await t.pumpWidget(
        helpers.app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result =
                  await showDialog<({String radio, String type, int limit})>(
                    context: context,
                    builder: (_) => BatchAssignmentDialog(
                      radios: kRadios.take(3).toList(),
                      tracks: kCustomPool.take(2).toList(),
                      splitTypes: true,
                      initialType: 'FreeRoam',
                      info: (radio, type) => const BatchAssignmentInfo(
                        total: 2,
                        added: 2,
                        limit: 32,
                        replacesBuiltin: false,
                      ),
                    ),
                  ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.numpad2);
      await t.pump();
      expect(find.byType(BatchAssignmentDialog), findsOneWidget);
      expect(result, isNull);
      expect(
        t
            .widget<RmButton>(find.byKey(const ValueKey('batch-type-Event')))
            .variant,
        RmButtonVariant.primary,
      );
      expect(
        t
            .widgetList<AssignmentRadioChoice>(
              find.byType(AssignmentRadioChoice),
            )
            .singleWhere((w) => w.selected)
            .radio
            .code,
        'R2',
      );
      await controlKey(t, LogicalKeyboardKey.digit3);
      expect(result, isNull);
      expect(
        t
            .widget<RmButton>(find.byKey(const ValueKey('batch-type-FreeRoam')))
            .variant,
        RmButtonVariant.primary,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(result, (radio: 'R3', type: 'FreeRoam', limit: 32));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      result = null;
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(BatchAssignmentDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'assignment digit handling ignores editing and unrelated modifiers',
    (t) async {
      viewport(t);
      var assignments = 0;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await t.pumpWidget(
        helpers.app(
          Builder(
            builder: (context) => Focus(
              onKeyEvent: (_, e) {
                if (assignmentKeyboardAvailable(context, e) &&
                    assignmentDigitShortcut(e, splitTypes: true) != null) {
                  assignments++;
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(controller: text, autofocus: true),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '123');
      await controlKey(t, LogicalKeyboardKey.digit1);
      await t.sendKeyEvent(LogicalKeyboardKey.numpad2);
      expect(assignments, 0);
      expect(text.text, '123');
      FocusManager.instance.primaryFocus!.unfocus();
      await t.pump();
      for (final modifier in [
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await t.sendKeyDownEvent(modifier);
        await t.sendKeyEvent(LogicalKeyboardKey.digit3);
        await t.sendKeyUpEvent(modifier);
      }
      expect(assignments, 0);
      expect(t.takeException(), isNull);
    },
  );
}
