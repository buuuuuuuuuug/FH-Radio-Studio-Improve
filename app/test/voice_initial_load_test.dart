import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;
import 'studio_v18_workflow_test.dart' as fixtures;

class _LoadingController extends StudioController {
  _LoadingController(super.prefs);
  void setBusy(bool value) => state = state.copyWith(busy: value);
  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'opening while the project loads waits then initializes exactly once',
    (t) async {
      final parent = await fixtures.fixture();
      final controller = _LoadingController(
        await SharedPreferences.getInstance(),
      );
      controller.setBusy(true);
      final container = ProviderContainer(
        parent: parent,
        overrides: [studioProvider.overrideWith((ref) => controller)],
      );
      addTearDown(container.dispose);
      final calls = <String>[];
      await base.open(
        t,
        const Size(1600, 900),
        calls,
        container: container,
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      expect(calls, isEmpty);
      controller.setBusy(false);
      await t.pumpAndSettle();
      expect(calls, ['scan']);
      expect(find.text('VO_A.assets.bank'), findsWidgets);
      controller.setBusy(true);
      await t.pump();
      controller.setBusy(false);
      await t.pumpAndSettle();
      expect(calls, ['scan']);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during project loading does not start a disposed workspace',
    (t) async {
      final parent = await fixtures.fixture();
      final controller = _LoadingController(
        await SharedPreferences.getInstance(),
      );
      controller.setBusy(true);
      final container = ProviderContainer(
        parent: parent,
        overrides: [studioProvider.overrideWith((ref) => controller)],
      );
      addTearDown(container.dispose);
      final calls = <String>[];
      await base.open(
        t,
        const Size(1600, 900),
        calls,
        container: container,
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await t.pumpWidget(const SizedBox.shrink());
      controller.setBusy(false);
      await t.pumpAndSettle();
      expect(calls, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
