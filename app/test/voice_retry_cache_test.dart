import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_overview.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'voice_replacement_test.dart' as page;
import 'voice_workbench_v2_test.dart' as data;
import 'studio_v18_workflow_test.dart' as fixtures;
import 'voice_clip_editor_test.dart' as clip;

class _VoiceStreams extends Fake implements PlayerStream {
  _VoiceStreams(this.completions);
  final Stream<bool> completions;
  @override
  Stream<bool> get completed => completions;
}

class _VoicePlayer extends Fake implements Player {
  final completions = StreamController<bool>.broadcast();
  PlayerState current = const PlayerState(duration: Duration(seconds: 2));
  var opens = 0;
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => current;
  @override
  PlayerStream get stream => _VoiceStreams(completions.stream);
  @override
  Future<void> pause() async {
    current = current.copyWith(playing: false);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    current = PlayerState(
      duration: const Duration(seconds: 2),
      playlist: Playlist([playable as Media]),
    );
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration position) async {
    current = current.copyWith(position: position, completed: false);
  }

  @override
  Future<void> play() async {
    current = current.copyWith(playing: true, completed: false);
  }

  void finish() {
    current = current.copyWith(completed: true, playing: false);
    completions.add(true);
  }
}

class _GameDirectoryController extends StudioController {
  _GameDirectoryController(super.prefs, StudioState initial) {
    state = initial;
  }
  void directory(String value) {
    state = state.copyWith(gameDir: value);
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'changing game directories in the same project starts a fresh resource scan',
    (t) async {
      final parent = await fixtures.fixture();
      final controller = _GameDirectoryController(
        await SharedPreferences.getInstance(),
        parent.read(studioProvider),
      );
      final container = ProviderContainer(
        parent: parent,
        overrides: [studioProvider.overrideWith((ref) => controller)],
      );
      addTearDown(container.dispose);
      var scans = 0;
      Future<Map<String, dynamic>> request(
        String action,
        Map<String, dynamic> options,
      ) async {
        if (action == 'scan') {
          scans++;
          return data.scan();
        }
        return {};
      }

      await page.open(
        t,
        const Size(1800, 950),
        [],
        container: container,
        responder: request,
      );
      expect(scans, 1);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      controller.directory('D:/Another-FH6-Installation');
      await page.open(
        t,
        const Size(1800, 950),
        [],
        container: container,
        responder: request,
      );
      expect(scans, 2);
      expect(find.text('A 条目 1'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'an old clip ending during preparation cannot clear the new stop button',
    (t) async {
      t.view.physicalSize = const Size(1800, 950);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final container = await fixtures.fixture(), player = _VoicePlayer();
      addTearDown(container.dispose);
      addTearDown(player.completions.close);
      final loading = Completer<Map<String, dynamic>>();
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(
              body: VoiceReplacementScreen(
                auditionPlayer: player,
                request: (action, options) async {
                  if (action == 'scan') return data.scan();
                  if (action == 'asset-info') {
                    return options['asset'] == 'y'
                        ? loading.future
                        : {
                            'path': 'x.wav',
                            'duration': 2.0,
                            'bins': List.filled(512, .5),
                          };
                  }
                  return {};
                },
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('路线'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('voice-play-asset:x')));
      await t.pumpAndSettle();
      expect(player.state.playing, isTrue);
      await t.tap(find.byKey(const ValueKey('voice-play-asset:y')));
      await t.pump();
      player.finish();
      await t.pump();
      loading.complete({
        'path': 'y.wav',
        'duration': 2.0,
        'bins': List.filled(512, .5),
      });
      await t.pumpAndSettle();
      expect(player.state.playing, isTrue);
      expect(player.opens, 2);
      await t.tap(find.byKey(const ValueKey('voice-play-asset:y')));
      await t.pumpAndSettle();
      expect(player.state.playing, isFalse);
      expect(player.opens, 2, reason: '再次点击必须停止，而不是重新加载播放');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'transport updates reuse the static waveform in main and overview',
    (t) async {
      await clip.open(t, 1100);
      ManualFocusWaveform wave() =>
          t.widget<ManualFocusWaveform>(find.byType(ManualFocusWaveform));
      final original = wave().bars;
      expect(
        t.widget<WaveformOverview>(find.byType(WaveformOverview)).bars,
        same(original),
      );
      wave().onSeek!(1);
      await t.pump();
      expect(wave().bars, same(original));
      await t.tap(find.byKey(const ValueKey('material-insert-silence')));
      await t.pumpAndSettle();
      expect(wave().bars, isNot(same(original)));
      expect(
        t.widget<WaveformOverview>(find.byType(WaveformOverview)).bars,
        same(wave().bars),
      );
      expect(t.takeException(), isNull);
    },
  );

  test('failed scans release their pending request and can retry', () async {
    final session = VoiceWorkspaceSession();
    var attempts = 0;
    Future<Map<String, dynamic>> load() async {
      attempts++;
      if (attempts == 1) throw const FormatException('暂时无法读取');
      return {'ok': true};
    }

    await expectLater(session.readScan(load), throwsFormatException);
    expect(session.scan, isNull);
    expect(await session.readScan(load), {'ok': true});
    expect(attempts, 2);
  });

  testWidgets('rescan retries the backend after the initial scan fails', (
    t,
  ) async {
    var attempts = 0;
    await page.open(
      t,
      const Size(1800, 950),
      [],
      responder: (action, options) async {
        if (action == 'scan') {
          if (++attempts == 1) throw const FormatException('暂时无法读取');
          return data.scan();
        }
        return {};
      },
    );
    expect(find.textContaining('暂时无法读取'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('voice-rescan')));
    await t.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('A 条目 1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'same filename in another directory does not reuse the selected bank',
    (t) async {
      final snapshot = data.scan();
      (snapshot['files'] as List).add({
        'name': 'VO_A.assets.bank',
        'path': 'D:/Game/other/VO_A.assets.bank',
        'relative_path': 'other/VO_A.assets.bank',
        'category': '活动与播报',
        'status': '待解析',
      });
      await page.open(
        t,
        const Size(1800, 950),
        [],
        responder: (action, options) async => action == 'scan' ? snapshot : {},
      );
      expect(find.text('A 条目 1'), findsOneWidget);
      await t.tap(
        find.byKey(const ValueKey('voice-resource-other/VO_A.assets.bank')),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('voice-prepare')), findsOneWidget);
      expect(find.text('A 条目 1'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during waveform loading cannot poison the project cache',
    (t) async {
      final container = await fixtures.fixture();
      addTearDown(container.dispose);
      final oldWave = Completer<Map<String, dynamic>>();
      var attempts = 0;
      Future<Map<String, dynamic>> request(
        String action,
        Map<String, dynamic> options,
      ) async {
        if (action == 'scan') return data.scan();
        if (action == 'asset-info') {
          if (++attempts == 1) return oldWave.future;
          return {
            'path': 'source.wav',
            'duration': 2.0,
            'bins': List.filled(512, .5),
          };
        }
        return {};
      }

      Future<void> openPage() => page.open(
        t,
        const Size(1800, 950),
        [],
        container: container,
        responder: request,
      );
      void openMaterial() =>
          t.widgetList<TrackCard>(find.byType(TrackCard)).first.onOpenEditor!();
      await openPage();
      await t.tap(find.text('路线'));
      await t.pumpAndSettle();
      openMaterial();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(attempts, 1);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await openPage();
      openMaterial();
      await t.pumpAndSettle();
      oldWave.completeError(const FormatException('旧处理已关闭'));
      await t.pumpAndSettle();
      expect(attempts, 2);
      expect(find.byType(ManualFocusWaveform), findsOneWidget);
      expect(find.textContaining('旧处理已关闭'), findsNothing);
      await t.tap(find.widgetWithText(RmButton, '取消'));
      await t.pumpAndSettle();
      openMaterial();
      await t.pumpAndSettle();
      expect(attempts, 2, reason: '成功读取的波形仍应直接复用');
      expect(t.takeException(), isNull);
    },
  );
}
