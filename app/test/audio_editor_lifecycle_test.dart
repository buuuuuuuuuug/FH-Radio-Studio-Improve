import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/screens/voice_replacement.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_editor.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'studio_v18_workflow_test.dart' as fixtures;
import 'voice_workbench_v2_test.dart' as voice;

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _Player extends Fake implements Player {
  int pauses = 0;
  @override
  PlayerStream get stream => _Streams();
  @override
  PlayerState get state => const PlayerState();
  @override
  Future<void> pause() async {
    pauses++;
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final pending in [false, true]) {
    testWidgets(
      'leaving voice editor during ${pending ? "loading" : "editing"} removes it with its page',
      (t) async {
        t.view.physicalSize = const Size(1800, 1000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final container = await fixtures.fixture();
        addTearDown(container.dispose);
        final loading = Completer<Map<String, dynamic>>();
        var renders = 0;
        final router = GoRouter(
          initialLocation: '/voices',
          routes: [
            ShellRoute(
              builder: (_, _, child) => Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 220, child: Text('导航')),
                    Expanded(child: child),
                  ],
                ),
              ),
              routes: [
                GoRoute(
                  path: '/voices',
                  builder: (_, _) => AudioEditorHost(
                    key: const ValueKey('voices'),
                    child: VoiceReplacementScreen(
                      request: (action, options) async {
                        if (action == 'scan') return voice.scan();
                        if (action == 'asset-info') {
                          return pending
                              ? loading.future
                              : {
                                  'path': 'source.wav',
                                  'duration': 2.0,
                                  'bins': List.filled(512, .5),
                                };
                        }
                        if (action == 'asset') renders++;
                        return {};
                      },
                    ),
                  ),
                ),
                GoRoute(
                  path: '/other',
                  builder: (_, _) => const Scaffold(body: Text('其他页面')),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: container,
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
        await t.tap(find.text('路线'));
        await t.pumpAndSettle();
        t.widgetList<TrackCard>(find.byType(TrackCard)).first.onOpenEditor!();
        if (pending) {
          await t.pump(const Duration(milliseconds: 300));
          await t.pump();
        } else {
          await t.pumpAndSettle();
        }
        expect(find.byType(VoiceClipEditor), findsOneWidget);
        router.go('/other');
        await t.pumpAndSettle();
        expect(find.text('其他页面'), findsOneWidget);
        expect(find.byType(VoiceClipEditor), findsNothing);
        if (pending) {
          loading.complete({'duration': 2.0, 'bins': List.filled(512, .5)});
        }
        await t.pumpAndSettle();
        expect(renders, 0);
        router.go('/voices');
        await t.pumpAndSettle();
        expect(find.byType(VoiceReplacementScreen), findsOneWidget);
        expect(find.byType(VoiceClipEditor), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'stinger editor and its local dialogs cannot survive shell navigation',
    (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final container = await fixtures.fixture();
      addTearDown(container.dispose);
      final player = _Player();
      final result = Completer<bool?>();
      final router = GoRouter(
        initialLocation: '/stingers',
        routes: [
          GoRoute(
            path: '/stingers',
            builder: (_, _) => AudioEditorHost(
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async => result.complete(
                      await showStingerEditor(
                        context,
                        assets: const [],
                        songs: const [],
                        player: player,
                        preferredWidth: 1080,
                        usedCount: 0,
                        play: (audio, {start, end, gain = 0}) async {},
                        call: (_, _) async => {},
                      ),
                    ),
                    child: const Text('打开台呼'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Text('其他页面')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            routerConfig: router,
          ),
        ),
      );
      await t.tap(find.text('打开台呼'));
      await t.pumpAndSettle();
      expect(find.byType(StingerEditor), findsOneWidget);
      router.go('/other');
      await t.pumpAndSettle();
      expect(find.byType(StingerEditor), findsNothing);
      expect(await result.future, isNull);
      expect(player.pauses, greaterThan(0));
      expect(t.takeException(), isNull);
    },
  );
}
