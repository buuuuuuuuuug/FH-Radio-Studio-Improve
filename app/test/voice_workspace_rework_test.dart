import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/core/voice_audition.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/shell/title_bar.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'voice_replacement_test.dart' as base;
import 'voice_workbench_v2_test.dart' as data;

Future<void> assign(WidgetTester tester) async {
  await tester.tap(find.text('路线'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('素材一'));
  final gesture = await tester.startGesture(tester.getCenter(find.text('素材一')));
  await gesture.moveBy(const Offset(-20, 0));
  await gesture.moveTo(
    tester.getCenter(find.byKey(const ValueKey('voice-entry-0'))),
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

class _Player extends Fake implements Player {
  final calls = <String>[];
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => const PlayerState(duration: Duration(seconds: 1));
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> open(Playable playable, {bool play = true}) async =>
      calls.add('open:$play');
  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async =>
      calls.add('mode:$mode');
  @override
  Future<void> setRate(double rate) async => calls.add('rate:$rate');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMicroseconds}');
  @override
  Future<void> play() async => calls.add('play');
}

class _CachedPlayer extends _Player {
  PlayerState _value = const PlayerState(duration: Duration(seconds: 1));
  @override
  PlayerState get state => _value;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    await super.open(playable, play: play);
    _value = PlayerState(
      duration: const Duration(seconds: 1),
      playlist: Playlist([playable as Media]),
    );
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('audition cannot autoplay before positioning at zero', () async {
    final player = _Player();
    await startVoiceAudition(player, 'voice.wav');
    expect(player.calls.first, 'pause');
    expect(player.calls[1], 'open:false');
    expect(
      player.calls.indexOf('seek:0'),
      lessThan(player.calls.indexOf('play')),
    );
    expect(player.calls.last, 'play');
    final cancelled = _Player();
    await startVoiceAudition(cancelled, 'old.wav', isCurrent: () => false);
    expect(cancelled.calls, isEmpty);
  });

  test(
    'repeat audition reuses the loaded media and seeks before playing',
    () async {
      final player = _CachedPlayer();
      await startVoiceAudition(player, 'cached.wav');
      await startVoiceAudition(player, 'cached.wav', start: .1);
      expect(player.calls.where((c) => c.startsWith('open:')), hasLength(1));
      expect(
        player.calls.indexOf('seek:100000'),
        lessThan(player.calls.lastIndexOf('play')),
      );
      await startVoiceAudition(player, 'another.wav');
      expect(player.calls.where((c) => c.startsWith('open:')), hasLength(2));
    },
  );

  test(
    'disk draft is separate from the saved plan and clears after saving',
    () async {
      final project = Directory.systemTemp.createTempSync('voice-draft-test-');
      addTearDown(() => project.deleteSync(recursive: true));
      final session = VoiceWorkspaceSession();
      final edits = <String, dynamic>{
        'bank': {
          '0': {'asset_id': 'tone'},
        },
      };
      final saved = <String, dynamic>{'bank': <String, dynamic>{}};
      await session.writeDraft(project.path, edits, saved);
      expect(
        (await VoiceWorkspaceSession().readDraft(project.path))!['edits'],
        edits,
      );
      expect(
        File('${project.path}/.fh-radio-studio/voices.json').existsSync(),
        isFalse,
      );
      await session.writeDraft(project.path, edits, edits);
      expect(await session.readDraft(project.path), isNull);
    },
  );

  testWidgets(
    'resource actions stay on one row and processing does not shift the workspace',
    (tester) async {
      var scans = 0;
      final pending = Completer<Map<String, dynamic>>();
      await base.open(
        tester,
        const Size(2000, 900),
        [],
        responder: (a, o) async {
          if (a == 'scan') return ++scans == 1 ? data.scan() : pending.future;
          return {};
        },
      );
      final rescan = find.byKey(const ValueKey('voice-rescan'));
      final choose = find.byKey(const ValueKey('voice-choose-resource'));
      expect(
        tester.getCenter(rescan).dy,
        closeTo(tester.getCenter(choose).dy, .1),
      );
      final before = tester
          .getTopLeft(find.byKey(const ValueKey('voice-table-groups')))
          .dy;
      await tester.tap(rescan);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('voice-table-groups'))).dy,
        before,
      );
      pending.complete(data.scan());
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('voice-table-groups'))).dy,
        before,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'draft and cached catalog survive leaving and remounting the page',
    (tester) async {
      final calls = <String>[];
      Future<Map<String, dynamic>> respond(
        String action,
        Map<String, dynamic> _,
      ) async => action == 'scan' ? data.scan() : {};
      await base.open(tester, const Size(2000, 900), calls, responder: respond);
      await assign(tester);
      expect(find.textContaining('1 条替换'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(VoiceReplacementScreen)),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Text('another page'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await base.open(
        tester,
        const Size(2000, 900),
        calls,
        container: container,
        responder: respond,
      );
      expect(calls, ['scan']);
      expect(find.textContaining('1 条替换'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-clear-0')), findsOneWidget);
      expect(
        tester
            .widget<RmButton>(find.byKey(const ValueKey('voice-clear-0')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('voice-clear-0')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('0 条替换'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条替换'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('comparison divider moves both ways and stays inside the table', (
    tester,
  ) async {
    await base.open(
      tester,
      const Size(2200, 900),
      [],
      responder: (a, o) async => a == 'scan' ? data.scan() : {},
    );
    final divider = find.byKey(const ValueKey('voice-comparison-divider'));
    final table = tester.getRect(
      find.byKey(const ValueKey('voice-table-groups')),
    );
    final initial = tester.getCenter(divider).dx;
    await tester.drag(divider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(divider).dx, closeTo(initial + 60, 1));
    await tester.drag(divider, const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(divider).dx, closeTo(initial - 40, 1));
    await tester.drag(divider, const Offset(5000, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(divider).dx, lessThan(table.right - 250));
    await tester.drag(divider, const Offset(-5000, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(divider).dx, greaterThan(table.left + 350));
    expect(
      tester.getRect(find.text('替换音频')).right,
      lessThanOrEqualTo(table.right + .5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'material actions stay aligned and double click edits without assigning',
    (tester) async {
      await base.open(
        tester,
        const Size(1600, 900),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await tester.tap(find.text('路线'));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('voice-material-x'));
      final play = find.byKey(const ValueKey('voice-play-asset:x'));
      final edit = find.byKey(const ValueKey('voice-delete-material-x'));
      expect(tester.getCenter(play).dy, closeTo(tester.getCenter(edit).dy, .1));
      expect(tester.getSize(card).height, lessThanOrEqualTo(62));
      await tester.tap(find.text('素材一'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('素材一'));
      await tester.pumpAndSettle();
      expect(find.text('语音素材'), findsOneWidget);
      expect(find.textContaining('0 条替换'), findsOneWidget);
      expect(find.text('管理'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [520.0, 720.0, 980.0]) {
    testWidgets('application title bar fits $width with a long project name', (
      tester,
    ) async {
      await base.open(
        tester,
        Size(width, 850),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(VoiceReplacementScreen)),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: Align(alignment: Alignment.topCenter, child: TitleBar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
