import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/core/voice_audition.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/screens/voices/voice_clip_editor.dart';
import 'package:fh_radio_studio/widgets/audio_editor_dialog.dart';
import 'package:fh_radio_studio/widgets/editor_columns.dart';
import 'package:fh_radio_studio/widgets/timing_dialog_frame.dart';
import 'voice_clip_editor_test.dart' as clip;
import 'voice_replacement_test.dart' as page;
import 'voice_workbench_v2_test.dart' as data;
import 'studio_v21_workflow_test.dart' as helpers;

class _NativePosition extends Fake implements NativePlayer {
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => '2.15';
}

class _TailPlayer extends Fake implements Player {
  @override
  NativePlayer get platform => _NativePosition();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'decoder EOF drains remaining samples without waiting for an exact final timestamp',
    () async {
      final watch = Stopwatch()..start();
      await waitForVoiceTail(_TailPlayer(), 2.42);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(269));
    },
  );
  test('changing the playback request cancels its pending EOF tail', () async {
    var calls = 0;
    await waitForVoiceTail(
      _TailPlayer(),
      2.42,
      isCurrent: () {
        calls++;
        return false;
      },
    );
    expect(calls, 1);
  });
  testWidgets(
    'silence arrows adjust 50 ms without losing manually entered durations',
    (t) async {
      await clip.open(t, 1200);
      final main = t.getRect(
        find.byKey(const ValueKey('material-main-column')),
      );
      final settings = t.getRect(
        find.byKey(const ValueKey('material-settings-panel')),
      );
      expect(settings.top, main.top);
      expect(settings.bottom, main.bottom);
      final input = find.byKey(const ValueKey('material-silence-ms'));
      String value() => t.widget<TextField>(input).controller!.text;
      await t.tap(find.byKey(const ValueKey('material-silence-step-50')));
      expect(value(), '150');
      await t.tap(find.byKey(const ValueKey('material-silence-step--50')));
      expect(value(), '100');
      await t.enterText(input, '375');
      await t.tap(find.byKey(const ValueKey('material-silence-step-50')));
      expect(value(), '425');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'editor columns match main height in their first layout, including LayoutBuilders',
    (t) async {
      var height = 310.0;
      late StateSetter update;
      await t.pumpWidget(
        helpers.app(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Center(
                child: SizedBox(
                  width: 900,
                  child: SingleChildScrollView(
                    child: EditorColumns(
                      main: LayoutBuilder(
                        builder: (context, box) => SizedBox(
                          key: const ValueKey('main-height'),
                          height: height,
                        ),
                      ),
                      side: Container(
                        key: const ValueKey('side-height'),
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(t.getSize(find.byKey(const ValueKey('side-height'))).height, 310);
      update(() => height = 520);
      await t.pump();
      expect(t.getSize(find.byKey(const ValueKey('side-height'))).height, 520);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'replacement name and folder participate in the comparison search',
    (t) async {
      final snapshot = data.scan();
      snapshot['plan']['banks']['A']['replacements'] = {
        '8': {'asset_id': 'x', 'start': 0, 'end': 2, 'gain_db': 0},
      };
      await page.open(
        t,
        const Size(1800, 950),
        [],
        responder: (a, o) async => a == 'scan' ? snapshot : {},
      );
      final field = find.descendant(
        of: find.byKey(const ValueKey('voice-entry-filter')),
        matching: find.byType(TextField),
      );
      for (final query in ['素材一', '导航/路线', '素材一 中文 8']) {
        await t.enterText(field, query);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('voice-entry-8')), findsOneWidget);
        expect(find.byKey(const ValueKey('voice-entry-0')), findsNothing);
      }
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'selection operations stay beside multi-select and file operations are last',
    (t) async {
      await page.open(
        t,
        const Size(2400, 950),
        [],
        responder: (a, o) async => a == 'scan' ? data.scan() : {},
      );
      await t.tap(find.byKey(const ValueKey('voice-export-text')));
      await t.pumpAndSettle();
      final multi = t.getRect(find.byKey(const ValueKey('voice-export-text')));
      final export = t.getRect(
        find.byKey(const ValueKey('voice-export-selected-text')),
      );
      final add = t.getRect(find.byKey(const ValueKey('voice-extract-assets')));
      final open = t.getRect(
        find.byKey(const ValueKey('voice-open-audio-folder')),
      );
      final forget = t.getRect(
        find.byKey(const ValueKey('voice-forget-audio')),
      );
      expect(export.top, multi.top);
      expect(add.top, multi.top);
      expect(export.left, greaterThan(multi.right));
      expect(open.left, greaterThan(add.right));
      expect(forget.left, greaterThan(open.right));
      await t.tap(find.byKey(const ValueKey('voice-toggle-all-entries')));
      await t.pumpAndSettle();
      expect(find.text('已选 50'), findsOneWidget);
      expect(find.text('取消全选'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('voice-toggle-all-entries')));
      await t.pumpAndSettle();
      expect(find.text('已选 0'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'used materials keep original text accent with a neutral surface',
    (t) async {
      final snapshot = data.scan();
      snapshot['plan']['banks']['A']['replacements'] = {
        '0': {'asset_id': 'x', 'start': 0, 'end': 2, 'gain_db': 0},
      };
      await page.open(
        t,
        const Size(1800, 950),
        [],
        responder: (a, o) async => a == 'scan' ? snapshot : {},
      );
      await t.tap(find.text('路线'));
      await t.pumpAndSettle();
      final cards = t.widgetList<TrackCard>(find.byType(TrackCard)).toList();
      expect(cards.firstWhere((c) => c.title == '素材一').neutral, isTrue);
      expect(cards.firstWhere((c) => c.title == '素材一').accentColor, isNull);
      expect(cards.firstWhere((c) => c.title == '素材二').neutral, isFalse);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'material modal is centered inside content and honors the configured width',
    (t) async {
      t.view.physicalSize = const Size(1400, 950);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        helpers.app(
          Row(
            children: [
              const SizedBox(width: 220, child: Text('导航')),
              Expanded(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => showAudioEditorDialog<void>(
                          context: context,
                          builder: (_) => VoiceClipEditor(
                            preferredWidth: 760,
                            asset: const {
                              'id': 'a',
                              'name': '测试素材',
                              'duration': 2.0,
                            },
                            folders: const ['未分类'],
                            load: () async => {
                              'path': 'source.wav',
                              'duration': 2.0,
                              'bins': List.filled(512, .5),
                            },
                          ),
                        ),
                        child: const Text('打开'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      final frame = t.getRect(find.byType(TimingDialogFrame));
      final dialog = t.getRect(
        find.byKey(const ValueKey('timing-dialog-panel')),
      );
      expect(dialog.width, 760);
      expect(dialog.center.dx, closeTo(810, .1));
      expect(frame.left, greaterThanOrEqualTo(220));
      expect(t.getRect(find.byType(BackdropFilter)).left, 220);
      expect(t.takeException(), isNull);
    },
  );
}
