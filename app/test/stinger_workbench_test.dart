import 'package:fh_radio_studio/state/stinger_state.dart';
import 'package:fh_radio_studio/state/layout_options.dart';
import 'package:flutter/material.dart';
import 'package:fh_radio_studio/widgets/timing_dialog_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_card.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_models.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_draggable.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/screens/stingers.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/widgets/feature_tour.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/widgets/rm_slider.dart';
import 'package:fh_radio_studio/widgets/time_input_field.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/screens/playlist/radio_column.dart';
import 'package:fh_radio_studio/widgets/audio_play_button.dart';
import 'package:fh_radio_studio/widgets/rm_select.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_assignment.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:media_kit/media_kit.dart';
import 'dart:async';
import 'studio_v18_workflow_test.dart' as fixtures;

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _Player extends Fake implements Player {
  var current = const PlayerState();
  @override
  PlayerState get state => current;
  @override
  PlayerStream get stream => _Streams();
  @override
  Future<void> pause() async {
    current = current.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    current = current.copyWith(playing: true);
  }
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  final a = {
    'asset_id': 'a',
    'start': 0,
    'end': 8,
    'gain_db': 0,
    'next_track': 6,
  };
  testWidgets('stinger cards do not open a secondary-click menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: StingerCard(
              title: 'Voice',
              subtitle: 'Audio',
              duration: 8,
              onEdit: () {},
              onAssign: () {},
              onRemove: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(StingerCard), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(find.text('分配至电台'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'clearing a replacement requires confirmation and sends a removal',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final calls = <Map<String, dynamic>>[];
      BuildContext? page;
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Builder(
              builder: (context) {
                page = context;
                return const Scaffold();
              },
            ),
          ),
        ),
      );
      final result = showStingerEditor(
        page!,
        station: const {'radio': 9},
        slot: {
          'id': 'R9:JP:a',
          'number': 1,
          'assignment': a,
          'original_preview': {
            'path': 'original.wav',
            'duration': 8,
            'bins': [.2],
          },
        },
        asset: null,
        assets: [
          {
            'id': 'a',
            'name': 'Voice',
            'duration': 8,
            'edit': a,
            'source_preview': {
              'path': 'source.wav',
              'duration': 8,
              'bins': [.2],
            },
          },
        ],
        songs: const [],
        player: _Player(),
        preferredWidth: 1400,
        usedCount: 1,
        deferSave: true,
        play: (_, {start, end, gain = 0}) async {},
        call: (action, input) async {
          expect(action, 'update');
          calls.add(input);
          return {'saved': true};
        },
        onSaved: (value) => saved = value,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RmButton, '清除替换'));
      await tester.pumpAndSettle();
      expect(find.text('清除此位置的替换？'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(
        find.descendant(
          of: find.byType(TimingDialogFrame),
          matching: find.widgetWithText(RmButton, '取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.widgetWithText(RmButton, '清除替换'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stinger-clear-confirm')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(calls.single['asset_id'], isNull);
      expect(saved?['clear'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  final b = {
    'asset_id': 'b',
    'start': 1,
    'end': 9,
    'gain_db': -3,
    'next_track': 5,
  };
  final slots = <Map<String, dynamic>>[
    {'id': 'R9:JP:a', 'assignment': a},
    {'id': 'R9:JP:b', 'assignment': b},
    {'id': 'R9:JP:c', 'assignment': null},
    {'id': 'R8:JP:a', 'assignment': null},
  ];
  final assets = <Map<String, dynamic>>[
    {'id': 'a', 'edit': a},
    {'id': 'b', 'edit': b},
  ];
  test('moving a used slot swaps edits without losing either assignment', () {
    expect(
      stingerDropChanges(
        slots: slots,
        assets: assets,
        drag: const StingerDrag(['a'], sourceSlot: 'R9:JP:a'),
        targetId: 'R9:JP:b',
      ),
      {'R9:JP:b': a, 'R9:JP:a': b},
    );
  });
  test('control dragging copies and leaves source intact', () {
    expect(
      stingerDropChanges(
        slots: slots,
        assets: assets,
        drag: const StingerDrag(['a'], sourceSlot: 'R9:JP:a'),
        targetId: 'R9:JP:b',
        copy: true,
      ),
      {'R9:JP:b': a},
    );
  });
  test('batch drop uses defaults and refuses to cross station boundary', () {
    expect(
      stingerDropChanges(
        slots: slots,
        assets: assets,
        drag: const StingerDrag(['a', 'b']),
        targetId: 'R9:JP:b',
      ),
      {'R9:JP:b': a, 'R9:JP:c': b},
    );
    expect(
      () => stingerDropChanges(
        slots: slots,
        assets: assets,
        drag: const StingerDrag(['a', 'b']),
        targetId: 'R9:JP:c',
      ),
      throwsFormatException,
    );
  });
  test('dropping on same position is a no-op', () {
    expect(
      stingerDropChanges(
        slots: slots,
        assets: assets,
        drag: const StingerDrag(['a'], sourceSlot: 'R9:JP:a'),
        targetId: 'R9:JP:a',
      ),
      isEmpty,
    );
  });
  testWidgets(
    'pool material double click edits, play click never starts a drag',
    (tester) async {
      var edits = 0, plays = 0, drops = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 280,
                  child: StingerCard(
                    dragBuilder: (body) => PlaylistDraggable<StingerDrag>(
                      data: const StingerDrag(['a']),
                      feedback: const Text('drag'),
                      child: body,
                    ),
                    title: 'Voice sample',
                    subtitle: '未分配',
                    duration: 8,
                    onPlay: () => plays++,
                    onEdit: () => edits++,
                  ),
                ),
                DragTarget<StingerDrag>(
                  onAcceptWithDetails: (_) => drops++,
                  builder: (context, c, r) => const SizedBox(
                    width: 280,
                    height: 100,
                    child: Text('Target'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final play = find.byTooltip('试听');
      await tester.tap(play);
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(drops, 0);
      expect(edits, 0);
      await tester.tap(find.text('Voice sample'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Voice sample'));
      await tester.pumpAndSettle();
      expect(edits, 1);
      await tester.drag(find.text('Voice sample'), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(drops, 1);
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [800.0, 1050.0, 1600.0]) {
    testWidgets(
      'cached stinger layout fits $width without restarting the CLI',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = await fixtures.fixture();
        final state = c.read(studioProvider);
        final key =
            '${state.projectDir}|${state.gameDir}|${state.targetLang}|false';
        c.read(stingerMemoryCacheProvider.notifier).state = {
          key: {
            'locale': state.targetLang,
            'available_locales': [state.targetLang],
            'assignment_count': 0,
            'stations': [
              for (final number in List.generate(9, (i) => i + 1))
                {
                  'radio': number,
                  'key': 'R$number:${state.targetLang}',
                  'original_count': 10,
                  'name': number == 9 ? 'Horizon Opus' : 'Horizon Wave',
                  'slots': [
                    for (var slot = 1; slot <= 10; slot++)
                      {
                        'id': 'R$number:${state.targetLang}:$slot',
                        'number': slot,
                        'sound_name': 'voice$slot',
                        'duration': 8,
                        'next_track': 6,
                      },
                  ],
                },
            ],
            'assets': [
              {'id': 'a', 'name': 'Voice', 'duration': 8, 'edit': a},
            ],
            'draft': {'assignments': {}, 'asset_edits': {}},
          },
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: ProviderScope(
              overrides: [
                automaticFeatureToursProvider.overrideWithValue(false),
              ],
              child: MaterialApp(
                theme: buildAppTheme(
                  brightness: Brightness.light,
                  accent: AppAccent.lime,
                ),
                home: const Scaffold(body: StingersScreen()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('池子'), findsOneWidget);
        if (width == 1600) {
          final last = find.byKey(
            ValueKey('stinger-slot-R1:${state.targetLang}:10'),
          );
          final column = find.byKey(const ValueKey('stinger-radio-1'));
          final gap =
              tester.getRect(column).bottom - tester.getRect(last).bottom;
          expect(
            gap,
            inInclusiveRange(7.0, 12.0),
            reason: 'Default height should fit exactly ten stingers',
          );
        }
        expect(find.text('Horizon Opus'), findsOneWidget);
        expect(find.text('正在准备台呼缓存'), findsNothing);
        expect(tester.takeException(), isNull);
        final search = find.byType(TextField).first;
        final height = tester.getSize(search).height;
        final station = find.byKey(const ValueKey('stinger-radio-9'));
        final before = tester.getRect(station);
        expect(
          find.byKey(const ValueKey('radio-height-slider')),
          findsOneWidget,
        );
        expect(find.text('当前准备包'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('游戏内')).dx,
          lessThan(tester.getTopLeft(find.text('准备包')).dx),
        );
        await tester.enterText(search, 'Voice');
        await tester.pumpAndSettle();
        expect(tester.getSize(search).height, height);
        expect(tester.getRect(station), before);
        expect(tester.widget<PlaylistColumn>(station).itemCount, 10);
        expect(find.text('刷新台呼'), findsNothing);
        expect(find.byKey(const ValueKey('stinger-save')), findsOneWidget);
        expect(find.text('复制游戏内排布'), findsOneWidget);
        expect(find.text('双击台呼或素材进入编辑'), findsNothing);
        if (width == 1600) {
          expect(
            (tester
                        .getCenter(
                          find.byKey(const ValueKey('stinger-cache-ready')),
                        )
                        .dy -
                    tester.getCenter(find.text('当前准备包')).dy)
                .abs(),
            lessThan(2),
          );
        }
        expect(
          find.byKey(const ValueKey('stinger-board-filter')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('stinger-language')), findsNothing);
        expect(find.text('custom · 自建'), findsOneWidget);
        expect(find.text('builtin · 锁定'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('stinger-asset-a')),
            matching: find.text('Voice'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(StingerAssignDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        // Wheel events in the full-page margin must reach the board scroll.
        final scrollable = find
            .descendant(
              of: find.byKey(const ValueKey('stinger-radio-board')),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(2, 500),
            scrollDelta: Offset(0, 300),
          ),
        );
        await tester.pump();
        expect(position.pixels, greaterThan(0));
        if (width == 1600) {
          c
              .read(stingerLayoutOptionsProvider.notifier)
              .setHeightMode(RadioHeightMode.oneRow);
          await tester.pumpAndSettle();
          final extent =
              tester
                  .getSize(find.byKey(const ValueKey('stinger-radio-1')))
                  .height +
              12;
          position.jumpTo(extent * .65);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            position.pixels,
            closeTo(extent, 1),
            reason: 'One-row mode snaps to the closest station row',
          );
          c
              .read(stingerLayoutOptionsProvider.notifier)
              .setHeightMode(RadioHeightMode.manual);
          position.jumpTo(0);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [800.0, 1400.0]) {
    testWidgets(
      'editor matches zoom direction, gain reset and key bindings at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = await fixtures.fixture();
        final player = _Player();
        final asset = <String, dynamic>{
          'id': 'a',
          'name': 'Voice',
          'duration': 20,
          'edit': {...a, 'gain_db': -3},
          'source_preview': {
            'path': 'source.wav',
            'duration': 20,
            'bins': List.filled(4096, .3),
          },
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              theme: buildAppTheme(
                brightness: Brightness.light,
                accent: AppAccent.lime,
              ),
              home: StingerEditor(
                asset: asset,
                assets: [asset],
                songs: const [],
                player: player,
                preferredWidth: width,
                usedCount: 0,
                play: (_, {start, end, gain = 0}) async {},
                call: (_, _) async => {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final slider = find.byType(RmSlider);
        expect(tester.widget<RmSlider>(slider).min, -6);
        expect(tester.widget<RmSlider>(slider).max, 6);
        expect(tester.widget<RmSlider>(slider).value, -3);
        await tester.ensureVisible(
          find.byKey(const ValueKey('stinger-gain-reset')),
        );
        await tester.tap(find.byKey(const ValueKey('stinger-gain-reset')));
        await tester.pumpAndSettle();
        expect(tester.widget<RmSlider>(slider).value, 0);
        final wave = find.byType(ManualFocusWaveform);
        await tester.ensureVisible(wave);
        double span() {
          final w = tester.widget<ManualFocusWaveform>(wave);
          return w.windowEnd! - w.windowStart;
        }

        final full = span();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(wave),
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(span(), lessThan(full));
        final zoomed = span();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(wave),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(span(), greaterThan(zoomed));
        double nextTime() => tester
            .widget<TimeInputField>(
              find.byKey(const ValueKey('stinger-time-next')),
            )
            .seconds;
        final before = nextTime();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(nextTime(), closeTo(before + .01, .000001));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(nextTime(), closeTo(before + .31, .000001));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(nextTime(), closeTo(before, .000001));
        expect(
          find.byKey(const ValueKey('stinger-editor-settings')),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(nextTime(), closeTo(before + .3, .000001));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'original and source playback controls keep their position and compact dialog height',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final player = _Player();
      final asset = <String, dynamic>{
        'id': 'a',
        'name': 'Voice',
        'duration': 20,
        'edit': a,
        'source_preview': {
          'path': 'source.wav',
          'duration': 20,
          'bins': [.2, .4],
        },
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: StingerEditor(
              station: const {'radio': 9},
              slot: {
                'id': 'R9:JP:a',
                'number': 1,
                'assignment': a,
                'original_preview': {
                  'path': 'original.wav',
                  'duration': 8,
                  'next_track': 6,
                  'bins': [.2, .3],
                },
              },
              assets: [asset],
              songs: const [],
              player: player,
              preferredWidth: 1400,
              usedCount: 1,
              play: (_, {start, end, gain = 0}) async {},
              call: (_, _) async => {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('stinger-original-toggle'));
      final originalRect = tester.getRect(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(RmButton, '原有台呼'), findsNothing);
      expect(find.widgetWithText(RmButton, '返回编辑'), findsOneWidget);
      expect(tester.getRect(toggle).top, originalRect.top);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(RmButton, '返回编辑'), findsNothing);
      expect(tester.getRect(toggle), originalRect);
      expect(find.text('试听选段'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dragging edits memory immediately, saves once, and undo restores saved state',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final state = c.read(studioProvider);
      final slotId = 'R9:${state.targetLang}:a';
      final data = <String, dynamic>{
        'locale': state.targetLang,
        'assignment_count': 0,
        'stations': [
          {
            'radio': 9,
            'key': 'R9:${state.targetLang}',
            'name': 'Opus',
            'original_count': 1,
            'slots': [
              {
                'id': slotId,
                'index': 0,
                'number': 1,
                'duration': 8,
                'next_track': 6,
                'assignment': null,
                'original_preview': {
                  'path': 'original.wav',
                  'duration': 8,
                  'bins': [.2],
                },
              },
            ],
          },
        ],
        'assets': [
          {
            'id': 'a',
            'name': 'Voice',
            'duration': 8,
            'edit': a,
            'source_preview': {
              'path': 'source.wav',
              'duration': 8,
              'bins': [.2],
            },
            'preview': {
              'path': 'cached.wav',
              'duration': 8,
              'edit': a,
              'bins': [.2],
            },
          },
        ],
        'draft': {
          'assignments': {},
          'asset_edits': {'a': a},
          'asset_names': {'a': 'Voice'},
        },
      };
      c.read(stingerMemoryCacheProvider.notifier).state = {
        '${state.projectDir}|${state.gameDir}|${state.targetLang}|false': data,
      };
      final pending = Completer<void>();
      final calls = <String>[];

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: ProviderScope(
            overrides: [
              automaticFeatureToursProvider.overrideWithValue(false),
              stingerDraftProvider.overrideWith(
                (ref) => StingerDraftController(ref),
              ),
              stingerRequestOverrideProvider.overrideWithValue((
                action,
                request,
              ) async {
                calls.add(action);
                if (action == 'restore-draft') {
                  await pending.future;
                  return {'saved': true};
                }
                throw StateError('Unexpected full audio refresh: $action');
              }),
            ],
            child: MaterialApp(
              theme: buildAppTheme(
                brightness: Brightness.light,
                accent: AppAccent.lime,
              ),
              home: const Scaffold(body: StingersScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final source = find.descendant(
        of: find.byKey(const ValueKey('stinger-asset-a')),
        matching: find.text('Voice'),
      );
      final target = find.byKey(ValueKey('stinger-slot-$slotId'));
      final buttonCount = find
          .descendant(
            of: find.byType(StingersScreen),
            matching: find.byType(IconButton),
          )
          .evaluate()
          .length;
      await tester.dragFrom(
        tester.getCenter(source),
        tester.getCenter(target) - tester.getCenter(source),
      );
      await tester.pump();
      expect(calls, isEmpty);
      expect(
        find.descendant(
          of: find.byType(StingersScreen),
          matching: find.byType(IconButton),
        ),
        findsNWidgets(buttonCount),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.widget<StingerCard>(target).title, 'Voice');
      expect(tester.widget<StingerCard>(target).onPlay, isNotNull);
      final from = tester.getCenter(
        find.descendant(of: target, matching: find.text('Voice')),
      );
      final pool = tester.getCenter(find.byKey(const ValueKey('stinger-pool')));
      await tester.dragFrom(from, pool - from);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.widget<StingerCard>(target).title, '台呼 01');
      expect(tester.widget<StingerCard>(target).onPlay, isNotNull);
      expect(
        tester
            .widget<RmButton>(find.byKey(const ValueKey('stinger-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('stinger-undo')));
      await tester.pumpAndSettle();
      expect(tester.widget<StingerCard>(target).title, 'Voice');
      await tester.tap(find.byKey(const ValueKey('stinger-save')));
      await tester.pump();
      expect(calls, ['restore-draft']);
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RmButton>(find.byKey(const ValueKey('stinger-save')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'audition remembers songs and lengths and uses station songs as first defaults',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture(), player = _Player();
      Widget editor() => UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: StingerEditor(
            station: const {'radio': 9},
            slot: const {
              'id': 'R9:JP:a',
              'number': 1,
              'original_preview': {
                'path': 'original.wav',
                'duration': 8,
                'next_track': 6,
                'bins': [.2, .3],
              },
            },
            assets: const [],
            songs: const [
              {'path': 'one.wav', 'name': 'One'},
              {'path': 'two.wav', 'name': 'Two'},
              {'path': 'three.wav', 'name': 'Three'},
            ],
            preferredSongs: const ['two.wav', 'three.wav'],
            contextKey: 'preferences-test|R9',
            player: player,
            preferredWidth: 1400,
            usedCount: 0,
            play: (_, {start, end, gain = 0}) async {},
            call: (_, _) async => {
              'path': 'seam.wav',
              'duration': 12,
              'bins': [.1, .2],
            },
          ),
        ),
      );
      Finder choice(String prefix) => find.byWidgetPredicate(
        (w) => w is RmSelect<String> && w.selectedPrefix == prefix,
      );
      await tester.pumpWidget(editor());
      await tester.pumpAndSettle();
      expect(tester.widget<RmSelect<String>>(choice('上一首')).value, 'two.wav');
      expect(tester.widget<RmSelect<String>>(choice('下一首')).value, 'three.wav');
      expect(find.text('原有 · 只读'), findsOneWidget);
      expect(
        tester.widget<AudioPlayButton>(find.byType(AudioPlayButton)).onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<RmButton>(find.byKey(const ValueKey('stinger-editor-save')))
            .onPressed,
        isNull,
      );
      tester.widget<RmSelect<String>>(choice('上一首')).onChanged!('one.wav');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stinger-seam-settings')), findsNothing);
      final beforeField = find.byKey(
        const ValueKey('stinger-seam-before-seconds'),
      );
      final afterField = find.byKey(
        const ValueKey('stinger-seam-after-seconds'),
      );
      expect(
        double.parse(tester.widget<TextFormField>(beforeField).initialValue!),
        6,
      );
      expect(
        double.parse(tester.widget<TextFormField>(afterField).initialValue!),
        4,
      );
      await tester.enterText(beforeField, '5.25');
      await tester.enterText(afterField, '8.5');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(editor());
      await tester.pumpAndSettle();
      expect(tester.widget<RmSelect<String>>(choice('上一首')).value, 'one.wav');
      expect(tester.widget<RmSelect<String>>(choice('下一首')).value, 'three.wav');
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('stinger-seam-before-seconds')),
            )
            .initialValue,
        '5.25',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('stinger-seam-after-seconds')),
            )
            .initialValue,
        '8.5',
      );
      final original = tester.getRect(find.widgetWithText(RmButton, '原有台呼'));
      final seam = tester.getRect(
        find.byKey(const ValueKey('stinger-editor-seam')),
      );
      expect(seam.left, greaterThan(original.right));
      expect(seam.center.dy, closeTo(original.center.dy, 1));
      await tester.enterText(
        find.byKey(const ValueKey('stinger-seam-before-seconds')),
        '99',
      );
      await tester.pumpAndSettle();
      expect(find.text('请输入 0–30 秒'), findsOneWidget);
      expect(
        tester
            .widget<RmButton>(find.byKey(const ValueKey('stinger-editor-seam')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('disabled playback controls stay visible', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: SizedBox(
            width: 280,
            child: StingerCard(
              title: 'Unavailable',
              subtitle: 'Waiting',
              duration: 4,
            ),
          ),
        ),
      ),
    );
    final icon = find.descendant(
      of: find.byType(StingerCard),
      matching: find.byType(IconButton),
    );
    expect(icon, findsOneWidget);
    expect(tester.widget<IconButton>(icon).onPressed, isNull);
  });
  testWidgets(
    'quick assign accepts keypad digits and selects the first free position',
    (tester) async {
      Map<String, int>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: RmButton(
                label: 'Open',
                onPressed: () async {
                  result = await showDialog<Map<String, int>>(
                    context: context,
                    builder: (_) => StingerAssignDialog(
                      count: 1,
                      radio: 9,
                      stations: [
                        {
                          'radio': 9,
                          'name': 'Opus',
                          'slots': [
                            {
                              'assignment': {'asset_id': 'used'},
                            },
                            {'assignment': null},
                          ],
                        },
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad9);
      await tester.pumpAndSettle();
      expect(result, {'radio': 9, 'start': 2});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pool editor does not offer assignment or bind the assignment shortcut',
    (tester) async {
      final c = await fixtures.fixture();
      final player = _Player();
      final actions = <String>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: StingerEditor(
              asset: {
                'id': 'a',
                'name': 'Voice',
                'duration': 8,
                'edit': a,
                'source_preview': {
                  'path': 'source.wav',
                  'duration': 8,
                  'bins': [.2],
                },
              },
              assets: [
                {
                  'id': 'a',
                  'name': 'Voice',
                  'duration': 8,
                  'edit': a,
                  'source_preview': {
                    'path': 'source.wav',
                    'duration': 8,
                    'bins': [.2],
                  },
                },
              ],
              songs: const [],
              player: player,
              preferredWidth: 1200,
              usedCount: 0,
              play: (_, {start, end, gain = 0}) async {},
              call: (action, input) async {
                actions.add(action);
                return {};
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stinger-editor-assign')), findsNothing);
      expect(actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [800.0, 920.0, 1100.0]) {
    testWidgets('stinger transport and inline timings fit a $width window', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final player = _Player();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: StingerEditor(
              station: const {'radio': 9},
              slot: const {
                'id': 'R9:JP:a',
                'number': 1,
                'original_preview': {
                  'path': 'original.wav',
                  'duration': 8,
                  'bins': [.2, .4],
                },
              },
              assets: const [],
              songs: const [
                {'path': 'one.wav', 'name': 'One'},
                {'path': 'two.wav', 'name': 'Two'},
              ],
              player: player,
              preferredWidth: 1400,
              usedCount: 0,
              play: (_, {start, end, gain = 0}) async {},
              call: (_, input) async => {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stinger-editor-seam')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stinger-seam-before-seconds')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'original stinger supports transition without replacement and repeat click pauses',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixtures.fixture();
      final player = _Player();
      final requests = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: StingerEditor(
              station: const {'radio': 9},
              slot: const {
                'id': 'R9:JP:a',
                'number': 1,
                'original_preview': {
                  'path': 'original.wav',
                  'duration': 8,
                  'bins': [.2, .4],
                },
              },
              readOnly: true,
              assets: const [],
              songs: const [
                {'path': 'one.wav', 'name': 'One'},
                {'path': 'two.wav', 'name': 'Two'},
              ],
              player: player,
              preferredWidth: 1400,
              usedCount: 0,
              play: (_, {start, end, gain = 0}) async {
                await player.play();
              },
              call: (action, input) async {
                expect(action, 'seam');
                requests.add(input);
                return {
                  'path': 'seam.wav',
                  'duration': 12,
                  'bins': [.2, .3],
                };
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stinger-editor-save')), findsNothing);
      final button = find.widgetWithText(RmButton, '试听歌曲衔接');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(requests.single['original'], true);
      expect(player.state.playing, true);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(player.state.playing, false);
      expect(tester.takeException(), isNull);
    },
  );
}
