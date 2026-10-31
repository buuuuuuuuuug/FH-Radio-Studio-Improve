import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_card.dart';
import 'package:fh_radio_studio/screens/replace_editor/transport_bar.dart';
import 'package:fh_radio_studio/state/editor_shortcuts.dart';
import 'package:fh_radio_studio/widgets/editor_shortcuts_dialog.dart';
import 'package:fh_radio_studio/widgets/package_loudness_dialog.dart';
import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  void viewport(WidgetTester t, {Size size = const Size(1365, 900)}) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
  }

  test(
    'new shortcuts persist and modifier-only snap shortcut is conflict checked',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = EditorShortcutController(prefs);
      expect(shortcutConflict(c.state), isNull);
      expect(c.state[EditorAction.manualTd]!.label, 'Ctrl + 1');
      expect(c.state[EditorAction.manualPl]!.label, 'Ctrl + 4');
      expect(c.state[EditorAction.markPlayback]!.label, 'Tab');
      expect(c.state[EditorAction.toggleSnap]!.label, 'Shift + Z');
      final custom = {
        ...c.state,
        EditorAction.manualTl: const EditorChord(
          LogicalKeyboardKey.keyL,
          ctrl: true,
          shift: true,
        ),
        EditorAction.toggleSnap: const EditorChord(
          LogicalKeyboardKey.keyS,
          alt: true,
        ),
      };
      c.save(custom);
      expect(
        EditorShortcutController(prefs).state[EditorAction.manualTl]!.label,
        'Ctrl + Shift + L',
      );
      expect(
        EditorShortcutController(prefs).state[EditorAction.toggleSnap]!.label,
        'Alt + S',
      );
      expect(
        shortcutConflict({
          ...c.state,
          EditorAction.manualTd: c.state[EditorAction.manualTl]!,
        }),
        isNotNull,
      );
      c.dispose();
    },
  );
  testWidgets(
    'snap shortcut records either modifier order and survives reload',
    (t) async {
      viewport(t);
      final f = await fixture.fixture();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(const EditorShortcutsButton()),
        ),
      );
      await t.tap(find.text('修改快捷键'));
      await t.pumpAndSettle();
      final row = find.byKey(const ValueKey('shortcut-toggleSnap'));
      await t.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await t.pumpAndSettle();
      await t.tap(row);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(
        f.container
            .read(editorShortcutsProvider)[EditorAction.toggleSnap]!
            .label,
        'Alt + Shift',
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'progress cells double click and configurable group shortcuts open all four groups',
    (t) async {
      viewport(t);
      final f = await fixture.fixture();
      final n = f.container.read(replaceEditorProvider('p1').notifier);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: helpers.app(
            const ReplaceEditorScreen(trackId: 'p1', enableAudio: false),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (final code in ['TD', 'PD', 'TL', 'PL']) {
        final cell = find.byKey(ValueKey('editor-progress-$code'));
        await t.tap(cell);
        await t.pump(const Duration(milliseconds: 70));
        await t.tap(cell);
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('manual-refine-overlay')),
          findsOneWidget,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
      }
      final keys = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.numpad1,
        LogicalKeyboardKey.numpad2,
        LogicalKeyboardKey.numpad3,
        LogicalKeyboardKey.numpad4,
      ];
      for (var i = 0; i < keys.length; i++) {
        await helpers.keyCombo(t, keys[i], ctrl: true);
        expect(
          find.byKey(const ValueKey('manual-refine-overlay')),
          findsOneWidget,
        );
        expect(
          n.state.activeGroup,
          [GroupKind.td, GroupKind.pd, GroupKind.tl, GroupKind.pl][i % 4],
        );
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
      }
      final ctl = f.container.read(editorShortcutsProvider.notifier);
      ctl.save({
        ...ctl.state,
        EditorAction.manualTl: const EditorChord(
          LogicalKeyboardKey.keyL,
          ctrl: true,
          shift: true,
        ),
      });
      await helpers.keyCombo(
        t,
        LogicalKeyboardKey.keyL,
        ctrl: true,
        shift: true,
      );
      expect(find.text('TrackLoop · 人工精修'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'manual playback, capture position, restore and zoom stay independent from main editor',
    (t) async {
      viewport(t, size: const Size(1500, 950));
      final base = await fixture.fixture();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            base.container.read(sharedPreferencesProvider),
          ),
          realPoolTracksProvider.overrideWithValue([
            PoolTrack(
              id: 'p1',
              title: 'Song',
              artist: 'Test',
              source: '${base.dir.path}/sources/song.wav',
              durationSec: 180,
              bpm: 120,
              key: '',
              configured: true,
              confirmed: 0,
              added: 'today',
            ),
          ]),
        ],
      );
      addTearDown(c.dispose);
      final f = (container: c, dir: base.dir);
      final n = f.container.read(replaceEditorProvider('p1').notifier);
      n.applyManualLoop(GroupKind.tl, 10, 100, confirm: false);
      n.saveToProject();
      n.setConfirmed(GroupKind.tl, false);
      n.setPlayhead(25);
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
      Finder overlay() => find.byKey(const ValueKey('manual-refine-overlay'));
      TransportBar transport() => t.widget<TransportBar>(
        find
            .descendant(of: overlay(), matching: find.byType(TransportBar))
            .first,
      );
      ManualFocusWaveform wave() =>
          t.widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform));
      expect(n.state.playhead, 25);
      await t.tap(find.byKey(const ValueKey('manual-refine-loop-preview')));
      await t.pumpAndSettle();
      expect(transport().state.playing, isTrue);
      expect(n.state.playing, isFalse);
      expect(n.state.playhead, 25);
      final position = transport().state.playhead;
      await helpers.keyCombo(t, LogicalKeyboardKey.tab);
      expect(wave().handles.first.t, closeTo(position, .001));
      expect(transport().state.playing, isTrue);
      expect(n.state.tl.start, 10);
      expect(n.state.playhead, 25);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyH, ctrl: true);
      expect(wave().handles.map((h) => h.t).toList(), [10, 100]);
      expect(transport().state.playing, isFalse);
      expect(transport().state.playbackMode, PlaybackMode.idle);
      transport().onSkipFwd();
      await t.pumpAndSettle();
      final duration = transport().state.ai.durationSec;
      await t.tap(find.byKey(const ValueKey('manual-zoom-in')));
      await t.pumpAndSettle();
      expect(
        wave().windowEnd,
        closeTo(duration, .001),
      ); // paused playback is at song end; selected endpoint remains 10s
      expect(wave().windowStart, greaterThan(0));
      // A loop nudge must not toggle the placement mode.
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pumpAndSettle();
      expect(wave().free, isFalse);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyZ, shift: true);
      expect(wave().free, isTrue);
      await helpers.keyCombo(t, LogicalKeyboardKey.keyZ, shift: true);
      expect(wave().free, isFalse);
      await t.tap(find.byKey(const ValueKey('manual-toggle-snap')));
      await t.pumpAndSettle();
      expect(wave().free, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(n.state.playhead, 25);
      expect(n.state.playing, isFalse);
      expect(n.state.tl.start, 10);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('both loop endpoints fit above footer at default manual width', (
    t,
  ) async {
    viewport(t);
    final f = await fixture.fixture();
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
    final bottom = t
        .getBottomLeft(find.byKey(const ValueKey('manual-time-loopEnd')))
        .dy;
    final footer = t
        .getTopLeft(find.byKey(const ValueKey('manual-refine-footer-divider')))
        .dy;
    expect(bottom, lessThan(footer));
    expect(t.takeException(), isNull);
  });
  testWidgets('main waveform can drag playhead across zoomed window', (
    t,
  ) async {
    viewport(t);
    final f = await fixture.fixture();
    final state = f.container.read(replaceEditorProvider('p1'));
    var position = -1.0;
    await t.pumpWidget(
      helpers.app(
        Center(
          child: SizedBox(
            width: 900,
            child: WaveformCard(
              state: state,
              aiPending: false,
              onSeek: (v) => position = v,
              onZoomIn: () {},
              onZoomOut: () {},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final paint = find
        .descendant(
          of: find.byType(WaveformCard),
          matching: find.byType(CustomPaint),
        )
        .first;
    final box = t.getRect(paint);
    await t.dragFrom(
      Offset(box.left + box.width * .2, box.center.dy),
      Offset(box.width * .4, 0),
    );
    await t.pumpAndSettle();
    expect(position, greaterThan(state.ai.durationSec * .5));
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'compact build dialog keeps actions under loudness controls and resets quality',
    (t) async {
      viewport(t);
      var quality = 50;
      final estimate = {
        'files': [
          for (var i = 1; i <= 9; i++)
            {
              'name': 'R${i}_Tracks.assets.bank',
              'rebuilt': true,
              'sizes': List.filled(100, 100000000),
              'upper_sizes': List.filled(100, 145000000),
              'limit_bytes': 2147483648,
            },
        ],
      };
      await t.pumpWidget(
        helpers.app(
          PackageLoudnessDialog(
            referenceMedianLufs: -18,
            initialOffsetLu: 3,
            previewInputLufs: -18,
            sizeEstimate: Future.value(estimate),
            onQualityChanged: (v) => quality = v,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('写入前还会再问一次'), findsNothing);
      final files = find.byKey(const ValueKey('package-file-estimates'));
      expect(t.getSize(files).height, lessThan(260));
      final action = t.getRect(find.text('准备电台包'));
      final list = t.getRect(files);
      expect(action.right, lessThan(list.left));
      final slider = t.widget<Slider>(
        find.byKey(const ValueKey('package-quality-slider')),
      );
      slider.onChanged!(90);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('package-quality-default')));
      await t.pump();
      expect(quality, 50);
      expect(t.takeException(), isNull);
    },
  );
}
