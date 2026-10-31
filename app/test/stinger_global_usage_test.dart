import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/stingers.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_card.dart';
import 'package:fh_radio_studio/state/stinger_state.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'studio_v18_workflow_test.dart' as fixtures;
import 'stinger_staged_edit_test.dart' as data;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('a material used by another voice locale cannot be removed', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final parent = await fixtures.fixture();
    final snapshot = data.catalog();
    snapshot['draft']['assignments'] = {'R1:EN:voice1': data.edit};
    final container = ProviderContainer(
      parent: parent,
      overrides: [
        stingerRequestOverrideProvider.overrideWithValue(
          (action, options) async => snapshot,
        ),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: StingersScreen()),
        ),
      ),
    );
    await t.pumpAndSettle();
    final card = t
        .widgetList<StingerCard>(find.byType(StingerCard))
        .firstWhere((card) => card.onAssign != null);
    card.onRemove!();
    await t.pumpAndSettle();
    expect(find.textContaining('其他语音语言', findRichText: true), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(
      container.read(stingerDraftProvider.notifier).snapshot['removed_assets'],
      isEmpty,
    );
    expect(t.takeException(), isNull);
  });
}
