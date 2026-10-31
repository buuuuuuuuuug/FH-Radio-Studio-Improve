import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

const highlight = ValueKey('feature-tour-highlight');

Future<SharedPreferences> preferences([
  Map<String, Object> values = const {},
]) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Widget app(
  SharedPreferences prefs,
  Widget body, {
  bool automatic = true,
  Brightness brightness = Brightness.light,
}) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    automaticFeatureToursProvider.overrideWithValue(automatic),
  ],
  child: MaterialApp(
    theme: buildAppTheme(brightness: brightness, accent: AppAccent.lime),
    home: Scaffold(body: body),
  ),
);

Widget page({bool enabled = true, VoidCallback? action}) => FeatureTourScope(
  page: TourPage.welcome,
  enabled: enabled,
  child: Column(
    children: [
      TourAnchor(
        'project',
        child: TextButton(
          onPressed: action ?? () {},
          child: const Text('底层操作'),
        ),
      ),
      const TourAnchor('help', child: FeatureTourButton()),
    ],
  ),
);

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'first visit highlights controls and completion persists across startup',
    (t) async {
      final prefs = await preferences();
      await t.pumpWidget(app(prefs, page()));
      await t.pumpAndSettle();
      expect(find.text('从工程开始'), findsOneWidget);
      expect(find.byKey(highlight), findsOneWidget);
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      expect(find.text('边用边了解'), findsOneWidget);
      await t.tap(find.text('上一步'));
      await t.pumpAndSettle();
      expect(find.text('从工程开始'), findsOneWidget);
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      await t.tap(find.text('知道了'));
      await t.pumpAndSettle();
      expect(prefs.getBool('rm.tour.v2.welcome'), isTrue);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpWidget(app(prefs, page()));
      await t.pumpAndSettle();
      expect(find.byKey(highlight), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('skip blocks click-through and manual replay remains available', (
    t,
  ) async {
    var actions = 0;
    final prefs = await preferences();
    await t.pumpWidget(app(prefs, page(action: () => actions++)));
    await t.pumpAndSettle();
    await t.tap(find.text('底层操作'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(actions, 0);
    await t.tap(find.text('跳过本页'));
    await t.pumpAndSettle();
    await t.tap(find.text('功能介绍'));
    await t.pumpAndSettle();
    expect(find.text('从工程开始'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsNothing);
    await t.tap(find.text('底层操作'));
    expect(actions, 1);
  });

  testWidgets('automatic tours wait until the page is ready', (t) async {
    final prefs = await preferences();
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    await t.pumpWidget(
      app(
        prefs,
        ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (_, value, _) => page(enabled: value),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsNothing);
    ready.value = true;
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
  });

  testWidgets('startup checks can defer the tour from the first frame', (
    t,
  ) async {
    final prefs = await preferences();
    final ready = ValueNotifier(true);
    addTearDown(ready.dispose);
    WidgetsBinding.instance.addPostFrameCallback((_) => ready.value = false);
    await t.pumpWidget(
      app(
        prefs,
        ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (_, value, _) => page(enabled: value),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsNothing);
    ready.value = true;
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
  });

  testWidgets('automatic preference does not prevent manual introductions', (
    t,
  ) async {
    final prefs = await preferences();
    await t.pumpWidget(app(prefs, page(), automatic: false));
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsNothing);
    await t.tap(find.text('功能介绍'));
    await t.pumpAndSettle();
    expect(find.byKey(highlight), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(find.text('边用边了解'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(find.text('从工程开始'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
  });

  testWidgets(
    'next step reveals a distant target and resize keeps the card usable',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1100, 760);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final prefs = await preferences();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await t.pumpWidget(
        app(
          prefs,
          FeatureTourScope(
            page: TourPage.welcome,
            child: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const TourAnchor(
                    'project',
                    child: SizedBox(height: 80, width: 260),
                  ),
                  const SizedBox(height: 1400),
                  const TourAnchor(
                    'help',
                    child: SizedBox(
                      key: ValueKey('distant-tour-target'),
                      height: 80,
                      width: 260,
                    ),
                  ),
                  const SizedBox(height: 500),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      expect(scroll.offset, greaterThan(700));
      final painter =
          t.widget<CustomPaint>(find.byKey(highlight)).painter as dynamic;
      expect(
        (painter.rect as Rect).overlaps(const Rect.fromLTWH(0, 0, 1100, 760)),
        isTrue,
      );
      t.view.physicalSize = const Size(360, 280);
      await t.pumpAndSettle();
      final revealed = t.getRect(
        find.byKey(const ValueKey('distant-tour-target')),
      );
      expect(revealed.top, greaterThanOrEqualTo(0));
      expect(revealed.bottom, lessThanOrEqualTo(280));
      expect(t.takeException(), isNull);
      await t.ensureVisible(find.text('知道了'));
      await t.tap(find.text('知道了'));
      await t.pumpAndSettle();
      expect(find.byKey(highlight), findsNothing);
    },
  );

  testWidgets(
    'nested refinement intro takes priority and does not mark song as seen',
    (t) async {
      final prefs = await preferences();
      await t.pumpWidget(
        app(
          prefs,
          FeatureTourScope(
            page: TourPage.song,
            child: FeatureTourScope(
              page: TourPage.refine,
              child: const Column(
                children: [
                  TourAnchor('waveform', child: SizedBox(height: 80)),
                  FeatureTourButton(),
                ],
              ),
            ),
          ),
          automatic: false,
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('功能介绍'));
      await t.pumpAndSettle();
      expect(find.text('放置端点'), findsOneWidget);
      await t.tap(find.text('知道了'));
      await t.pumpAndSettle();
      expect(prefs.getBool('rm.tour.v2.refine'), isTrue);
      expect(prefs.getBool('rm.tour.v2.song'), isNull);
    },
  );

  testWidgets('dark theme and disposed pages leave no overlay or async error', (
    t,
  ) async {
    final prefs = await preferences();
    await t.pumpWidget(app(prefs, page(), brightness: Brightness.dark));
    await t.pumpAndSettle();
    expect(find.text('从工程开始'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
