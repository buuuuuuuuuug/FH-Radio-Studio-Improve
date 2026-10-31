import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_overview.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/widgets/time_input_field.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'studio_v18_workflow_test.dart' as fixtures;

class _Streams extends Fake implements PlayerStream {
  _Streams(this.positions);
  final Stream<Duration> positions;
  @override
  Stream<Duration> get position => positions;
  @override
  Stream<bool> get playing => const Stream.empty();
}

class _Player extends Fake implements Player {
  final positions = StreamController<Duration>.broadcast();
  var current = const PlayerState();
  final seeks = <Duration>[];
  @override
  PlayerState get state => current;
  @override
  PlayerStream get stream => _Streams(positions.stream);
  void emit(double seconds) {
    final value = Duration(microseconds: (seconds * 1e6).round());
    current = current.copyWith(position: value);
    positions.add(value);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    emit(value.inMicroseconds / 1e6);
  }

  @override
  Future<void> pause() async => current = current.copyWith(playing: false);
  @override
  Future<void> play() async => current = current.copyWith(playing: true);
}

Future<_Player> _editor(
  WidgetTester tester, {
  bool original = false,
  List<Map<String, dynamic>>? plays,
  bool cached = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = await fixtures.fixture();
  final player = _Player();
  addTearDown(player.positions.close);
  const edit = {
    'asset_id': 'voice',
    'start': 2,
    'end': 16,
    'next_track': 10,
    'gain_db': 0,
  };
  final asset = <String, dynamic>{
    'id': 'voice',
    'name': 'Voice',
    'duration': 20,
    'edit': edit,
    'source_preview': {
      'path': 'source.wav',
      'duration': 20,
      'bins': List.filled(4096, .3),
    },
    if (cached)
      'preview': {'path': 'cropped.wav', 'duration': 14, 'edit': edit},
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
            'assignment': original ? null : edit,
            'original_preview': {
              'path': 'original.wav',
              'duration': 16,
              'next_track': 12,
              'bins': [.2, .4],
            },
          },
          assets: original ? [] : [asset],
          songs: const [
            {'path': 'before.wav', 'name': 'Before'},
            {'path': 'after.wav', 'name': 'After'},
          ],
          player: player,
          preferredWidth: 1400,
          usedCount: 1,
          play: (audio, {start, end, gain = 0}) async {
            plays?.add({'path': audio['path'], 'start': start, 'end': end});
            player.current = player.current.copyWith(
              position: Duration.zero,
              playing: true,
            );
          },
          call: (_, input) async => {
            'path': 'mixed.wav',
            'duration': 23.4,
            'stinger_start': 5.4,
            'next_track': 17.4,
            'bins': [.9, .8, .7],
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return player;
}

ManualFocusWaveform _wave(WidgetTester tester) =>
    tester.widget(find.byType(ManualFocusWaveform));
Map<String, double> _markers(WidgetTester tester) => {
  for (final h in _wave(tester).handles) h.label: h.t,
};

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final cached in [false, true]) {
    testWidgets(
      'playing at B and replaying after EOF restart the chosen clip: cached=$cached',
      (tester) async {
        final plays = <Map<String, dynamic>>[];
        final player = await _editor(tester, cached: cached, plays: plays);
        _wave(tester).onSeek!(16);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('stinger-editor-play')));
        await tester.pumpAndSettle();
        expect(plays.single['start'], cached ? 0 : 2);
        expect(plays.single['path'], cached ? 'cropped.wav' : 'source.wav');
        expect(plays.single['end'], cached ? null : 16);
        player.current = player.current.copyWith(
          position: Duration(seconds: cached ? 14 : 16),
          duration: Duration(seconds: cached ? 14 : 20),
          playing: false,
          completed: true,
        );
        await tester.tap(find.byKey(const ValueKey('stinger-editor-play')));
        await tester.pumpAndSettle();
        expect(plays, hasLength(2));
        expect(plays.last['start'], cached ? 0 : 2);
        expect(plays.last['end'], cached ? null : 16);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final original in [false, true]) {
    testWidgets(
      'seam keeps material clock, markers and seek mapping: original=$original',
      (tester) async {
        final player = await _editor(tester, original: original);
        final duration = _wave(tester).duration;
        final markers = _markers(tester);
        expect(
          tester
              .getBottomRight(find.byKey(const ValueKey('stinger-time-next')))
              .dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('stinger-editor-save')))
                .dy,
          ),
        );
        final end = tester
            .widget<TimeInputField>(
              find.byKey(const ValueKey('stinger-time-end')),
            )
            .seconds;
        await tester.tap(find.byKey(const ValueKey('stinger-editor-seam')));
        await tester.pumpAndSettle();
        expect(_wave(tester).duration, duration);
        expect(_markers(tester), markers);
        expect(markers['B'], 16);
        expect(
          tester
              .widget<TimeInputField>(
                find.byKey(const ValueKey('stinger-time-end')),
              )
              .seconds,
          end,
        );
        expect(find.textContaining('台呼前音乐'), findsWidgets);
        player.emit(6.4);
        await tester.pumpAndSettle();
        final origin = original ? 0.0 : 2.0;
        expect(_wave(tester).playhead, closeTo(origin + 1, 1e-6));
        _wave(tester).onPlace(10, isMove: false);
        await tester.pumpAndSettle();
        expect(
          player.seeks.last.inMicroseconds / 1e6,
          closeTo(10 - origin + 5.4, 1e-6),
        );
        expect(_markers(tester), markers);
        player.emit(0);
        await tester.pumpAndSettle();
        expect(_wave(tester).playhead, origin);
        player.emit(23);
        await tester.pumpAndSettle();
        expect(_wave(tester).playhead, 16);
        expect(find.textContaining('台呼后音乐'), findsOneWidget);
        expect(_wave(tester).duration, duration);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'overview drags without jumping and zoom follows playback instead of active N',
    (tester) async {
      final player = await _editor(tester);
      _wave(tester).onZoom!(.5);
      await tester.pumpAndSettle();
      expect(_wave(tester).windowStart, 0);
      expect(_wave(tester).windowEnd, 10);
      final overview = find.byKey(const ValueKey('stinger-waveform-overview'));
      expect(tester.widget(overview), isA<WaveformOverview>());
      final rect = tester.getRect(overview);
      final drag = await tester.startGesture(
        Offset(rect.left + rect.width * .25, rect.center.dy),
      );
      await drag.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      await drag.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      final view = _wave(tester);
      expect(view.windowEnd! - view.windowStart, 10);
      expect(view.windowStart, greaterThan(0));
      expect(view.windowStart, lessThan(3));
      await drag.up();
      expect(_markers(tester), {'A': 2.0, 'B': 16.0, 'N': 12.0});
      await tester.tap(find.byKey(const ValueKey('stinger-editor-play')));
      await tester.pumpAndSettle();
      player.emit(14);
      await tester.pumpAndSettle();
      expect(_wave(tester).windowStart, 10);
      expect(_wave(tester).windowEnd, 20);
      _wave(tester).onZoom!(.5);
      await tester.pumpAndSettle();
      expect(_wave(tester).windowStart, closeTo(11.5, 1e-6));
      expect(_wave(tester).windowEnd, closeTo(16.5, 1e-6));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'seam and returning to material keep zoom and source-clock position',
    (tester) async {
      final player = await _editor(tester);
      _wave(tester).onZoom!(.5);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stinger-editor-seam')));
      await tester.pumpAndSettle();
      expect(_wave(tester).windowEnd, 10);
      player.emit(8.4);
      await tester.pumpAndSettle();
      expect(_wave(tester).playhead, closeTo(5, 1e-6));
      await tester.tap(find.byKey(const ValueKey('stinger-original-toggle')));
      await tester.pumpAndSettle();
      expect(_wave(tester).playhead, closeTo(5, 1e-6));
      expect(_wave(tester).windowEnd, 10);
      expect(
        tester
            .widget<RmButton>(
              find.byKey(const ValueKey('stinger-original-toggle')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
