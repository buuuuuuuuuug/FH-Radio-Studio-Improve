import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:fh_radio_studio/state/editor_shortcuts.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/transport_bar.dart';
import 'package:fh_radio_studio/shell/app_shell.dart';
import 'package:fh_radio_studio/tweaks/tweaks_panel.dart';
import 'package:fh_radio_studio/widgets/quick_assign_dialog.dart';
import 'editor_playlist_upgrade_test.dart' as editor;
import 'studio_v18_workflow_test.dart' as playlist;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  void viewport(WidgetTester t, Size size) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
  }

  test('version 7 defaults migrate and custom bindings survive', () async {
    SharedPreferences.setMockInitialValues({
      'editor.shortcuts.version': 7,
      'editor.shortcuts.v1': jsonEncode({
        'manualTd': const EditorChord(
          LogicalKeyboardKey.digit1,
          ctrl: true,
          shift: true,
        ).toJson(),
        'previous': const EditorChord(
          LogicalKeyboardKey.arrowUp,
          ctrl: true,
          shift: true,
        ).toJson(),
        'markPlayback': const EditorChord(
          LogicalKeyboardKey.keyM,
          ctrl: true,
        ).toJson(),
        'toggleSnap': const EditorChord(
          LogicalKeyboardKey.altLeft,
          alt: true,
          shift: true,
        ).toJson(),
        'play': const EditorChord(LogicalKeyboardKey.keyP, ctrl: true).toJson(),
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final c = EditorShortcutController(prefs);
    expect(c.state[EditorAction.manualTd]!.label, 'Ctrl + 1');
    expect(c.state[EditorAction.previous]!.label, 'Shift + ↑');
    expect(c.state[EditorAction.markPlayback]!.label, 'Tab');
    expect(c.state[EditorAction.toggleSnap]!.label, 'Shift + Z');
    expect(c.state[EditorAction.freePlace]!.label, 'Z');
    expect(c.state[EditorAction.play]!.label, 'Ctrl + P');
    expect(shortcutConflict(c.state), isNull);
    c.save({
      ...c.state,
      EditorAction.markPlayback: const EditorChord(LogicalKeyboardKey.f9),
    });
    expect(
      EditorShortcutController(prefs).state[EditorAction.markPlayback]!.label,
      'F9',
    );
    c.dispose();
  });
  test(
    'version 8 group defaults migrate while custom bindings survive',
    () async {
      SharedPreferences.setMockInitialValues({
        'editor.shortcuts.version': 8,
        'editor.shortcuts.v1': jsonEncode({
          'manualTd': const EditorChord(
            LogicalKeyboardKey.digit1,
            shift: true,
          ).toJson(),
          'manualPd': const EditorChord(
            LogicalKeyboardKey.digit2,
            shift: true,
          ).toJson(),
          'manualTl': const EditorChord(
            LogicalKeyboardKey.digit3,
            shift: true,
          ).toJson(),
          'manualPl': const EditorChord(
            LogicalKeyboardKey.f8,
            ctrl: true,
          ).toJson(),
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final c = EditorShortcutController(prefs);
      expect(c.state[EditorAction.manualTd]!.label, 'Ctrl + 1');
      expect(c.state[EditorAction.manualPd]!.label, 'Ctrl + 2');
      expect(c.state[EditorAction.manualTl]!.label, 'Ctrl + 3');
      expect(c.state[EditorAction.manualPl]!.label, 'Ctrl + F8');
      c.save(c.state);
      expect(prefs.getInt('editor.shortcuts.version'), 10);
      expect(
        EditorShortcutController(prefs).state[EditorAction.manualPl]!.label,
        'Ctrl + F8',
      );
      c.dispose();
    },
  );
  test('number row and keypad aliases share conflict detection', () {
    final keys = defaultEditorShortcuts();
    keys[EditorAction.assign] = const EditorChord(
      LogicalKeyboardKey.numpad1,
      ctrl: true,
    );
    expect(shortcutConflict(keys), isNotNull);
    expect(
      const EditorChord(LogicalKeyboardKey.numpad2, ctrl: true).token,
      const EditorChord(LogicalKeyboardKey.digit2, ctrl: true).token,
    );
  });
  for (final width in [680.0, 900.0, 1040.0, 1080.0, 1180.0]) {
    testWidgets('author and header actions stay aligned at $width', (t) async {
      viewport(t, Size(width, 1000));
      final f = await editor.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      );
      await t.pumpAndSettle();
      final author = find.byKey(const ValueKey('editor-artist'));
      expect(author, findsOneWidget);
      final title = t.getRect(find.byKey(const ValueKey('editor-heading')));
      final save = t.getRect(find.byKey(const ValueKey('editor-save')));
      expect(save.left, greaterThan(title.right));
      expect((save.center.dy - title.center.dy).abs(), lessThan(65));
      expect(
        t.getRect(find.byKey(const ValueKey('editor-title'))).bottom,
        lessThanOrEqualTo(t.getRect(author).top),
      );
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    });
  }
  testWidgets('transport stays on one line at ordinary narrow widths', (
    t,
  ) async {
    viewport(t, const Size(1000, 900));
    final f = await editor.fixture();
    final state = f.container.read(replaceEditorProvider('p1'));
    for (final width in [500.0, 620.0, 790.0]) {
      await t.pumpWidget(
        helpers.app(
          Center(
            child: SizedBox(
              width: width,
              child: TransportBar(
                state: state,
                aiPending: false,
                onTogglePlay: () {},
                onRewind: () {},
                onSkipFwd: () {},
                trailing: const SizedBox(
                  width: 100,
                  height: 32,
                  child: Text('试听设置'),
                ),
              ),
            ),
          ),
        ),
      );
      final play = t.getRect(find.byKey(const ValueKey('editor-play-inline')));
      final settings = t.getRect(find.text('试听设置'));
      expect((play.center.dy - settings.center.dy).abs(), lessThan(12));
      expect(t.getSize(find.byType(TransportBar)).height, lessThan(80));
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    }
  });
  testWidgets(
    'Z temporarily frees placement, Shift Z toggles, Tab marks without traversing focus',
    (t) async {
      viewport(t, const Size(1365, 1000));
      final f = await editor.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      );
      await t.pumpAndSettle();
      await helpers.keyCombo(t, LogicalKeyboardKey.digit3, ctrl: true);
      await t.pumpAndSettle();
      ManualFocusWaveform wave() =>
          t.widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform));
      expect(wave().free, isFalse);
      await t.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
      await t.pump();
      expect(wave().free, isTrue);
      await t.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
      await t.pump();
      expect(wave().free, isFalse);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyZ, shift: true);
      expect(wave().free, isTrue);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyZ, shift: true);
      expect(wave().free, isFalse);
      final manualTransport = find.descendant(
        of: find.byKey(const ValueKey('manual-refine-overlay')),
        matching: find.byType(TransportBar),
      );
      t.widget<TransportBar>(manualTransport).onRewind();
      await t.pumpAndSettle();
      final position = t.widget<TransportBar>(manualTransport).state.playhead;
      await t.tap(
        find
            .descendant(
              of: find.byKey(const ValueKey('manual-refine-overlay')),
              matching: find.byType(TextField),
            )
            .first,
      );
      await t.pumpAndSettle();
      await t.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
      await t.pump();
      expect(wave().free, isTrue);
      await t.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
      await t.pump();
      expect(wave().free, isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      expect(
        wave().handles.firstWhere((h) => h.active).t,
        closeTo(position, .001),
      );
      expect(f.container.read(replaceEditorProvider('p1')).playing, isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    },
  );
  testWidgets(
    'settings close on a main content click without swallowing its action',
    (t) async {
      viewport(t, const Size(1365, 1000));
      final c = await playlist.fixture();
      var clicks = 0;
      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          ShellRoute(
            builder: (context, state, child) => AppShell(child: child),
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => GestureDetector(
                  key: const ValueKey('main-click'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => clicks++,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp.router(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            routerConfig: router,
          ),
        ),
      );
      await t.pumpAndSettle();
      c.read(settingsExpandedProvider.notifier).state = true;
      await t.pumpAndSettle();
      expect(find.byType(TweaksPanel), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('main-click')));
      await t.pumpAndSettle();
      expect(c.read(settingsExpandedProvider), isFalse);
      expect(clicks, 1);
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    },
  );
  testWidgets(
    'assignment dialog separates station names, counts and keyboard hints',
    (t) async {
      viewport(t, const Size(900, 900));
      final c = await playlist.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: helpers.app(QuickAssignDialog(track: kCustomPool.first)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('分配至电台'), findsOneWidget);
      expect(find.text('Horizon Pulse'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-assign-R1')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpAndSettle();
    },
  );
}
