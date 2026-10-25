import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/app_info.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/core/song_browse.dart';
import 'package:fh_radio_studio/core/studio_http_proxy.dart';
import 'package:fh_radio_studio/core/waveform_cache.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/audio_analysis_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/state/editor_options.dart';
import 'package:fh_radio_studio/state/waveform_batch_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/editor_options_controls.dart';
import 'package:fh_radio_studio/widgets/song_browse_controls.dart';
import 'editor_playlist_upgrade_test.dart' show fixture;

PoolTrack song(String source) => PoolTrack(
  id: source,
  title: source,
  artist: 'Artist',
  source: source,
  durationSec: 180,
  bpm: 0,
  key: '',
  configured: false,
  confirmed: 0,
  added: 'today',
);
final payload = <String, dynamic>{
  'waveform': {
    'bins': [
      {'norm_peak': 0.4},
    ],
  },
};

void main() {
  test('coarse waveform cache is upgraded before detailed editing', () async {
    final f = await fixture();
    final source = '${f.dir.path}/sources/song.wav';
    await WaveformCache.write(f.dir.path, source, {
      'samples': 8640000,
      'waveform': {
        'bins': List.filled(320, {'norm_peak': .4}),
      },
    });
    expect(await WaveformCache.read(f.dir.path, source), isNotNull);
    expect(
      await WaveformCache.read(f.dir.path, source, minimumBins: 8192),
      isNull,
    );
    await WaveformCache.write(f.dir.path, source, {
      'samples': 8640000,
      'waveform': {
        'bins': List.filled(8192, {'norm_peak': .5}),
      },
    });
    WaveformCache.clearMemory();
    final detailed = await WaveformCache.read(
      f.dir.path,
      source,
      minimumBins: 8192,
    );
    expect((detailed!['waveform'] as Map)['bins'], hasLength(8192));
  });
  test('short audio accepts all available waveform samples', () async {
    final f = await fixture();
    final source = '${f.dir.path}/sources/song.wav';
    await WaveformCache.write(f.dir.path, source, {
      'samples': 32,
      'waveform': {
        'bins': List.filled(32, {'norm_peak': .5}),
      },
    });
    expect(
      await WaveformCache.read(f.dir.path, source, minimumBins: 8192),
      isNotNull,
    );
  });
  test(
    'AI results preserve the detailed waveform already in the editor',
    () async {
      final f = await fixture();
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            f.container.read(sharedPreferencesProvider),
          ),
          audioAnalysisCliRunnerProvider.overrideWithValue(
            (root, args, {cancellationToken, onStdout, onStderr}) async =>
                CliRunResult(
                  commandLine: 'test',
                  exitCode: 0,
                  stderr: '',
                  stdout: jsonEncode({
                    'path': '${f.dir.path}/sources/song.wav',
                    'duration_sec': 180,
                    'sample_rate': 48000,
                    'samples': 8640000,
                    'bpm': 120,
                    'waveform': {
                      'bins': List.filled(320, {'norm_peak': .4}),
                    },
                  }),
                ),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.read(editorOptionsProvider.notifier).update(manualOnly: false);
      final editorSubscription = c.listen(
        replaceEditorProvider('p1'),
        (_, _) {},
      );
      addTearDown(editorSubscription.close);
      final editor = c.read(replaceEditorProvider('p1').notifier);
      final values = List.generate(8192, (i) => .1 + (i % 17) / 100);
      editor.state = editor.state.copyWith(
        ai: editor.state.ai.copyWith(waveformPeaks: values),
      );
      await editor.analyze();
      expect(editor.state.error, isNull);
      expect(editor.state.ai.waveformPeaks, values);
      final source = '${f.dir.path}/sources/song.wav';
      await WaveformCache.write(f.dir.path, source, {
        'duration_sec': 180,
        'sample_rate': 48000,
        'samples': 8640000,
        'waveform': {
          'bins': List.generate(8192, (i) => {'norm_peak': values[i]}),
        },
      });
      final realProvider = replaceEditorProvider(realTrackIdForPath(source));
      final realSubscription = c.listen(realProvider, (_, _) {});
      addTearDown(realSubscription.close);
      final realEditor = c.read(realProvider.notifier);
      await realEditor.analyze();
      expect(realEditor.state.error, isNull);
      expect(realEditor.state.ai.waveformPeaks, hasLength(8192));
    },
  );
  test(
    'saving detected beats does not downgrade a detailed waveform cache',
    () async {
      final f = await fixture();
      final source = '${f.dir.path}/sources/song.wav';
      await WaveformCache.write(f.dir.path, source, {
        'waveform': {
          'bins': List.filled(8192, {'norm_peak': .5}),
        },
      });
      await WaveformCache.write(f.dir.path, source, {
        'beats': [0.1, .6, 1.1],
        'waveform': {
          'bins': List.filled(320, {'norm_peak': .4}),
        },
      });
      final cached = await WaveformCache.read(f.dir.path, source);
      expect(((cached!['waveform'] as Map)['bins'] as List).length, 8192);
      expect(cached['beats'], [.1, .6, 1.1]);
    },
  );
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test('modified time displays local date and exact minute', () {
    expect(
      formatSongModifiedMinute(DateTime(2026, 10, 13, 9, 4, 59)),
      '2026-10-13 09:04',
    );
    expect(formatSongModifiedMinute(null), '—');
  });
  test(
    'localized app name stays out of HTTP headers, secure proxy handles local bypass',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) {
        request.response.write(request.headers.value('user-agent'));
        request.response.close();
      });
      final client = StudioHttpProxy({
        'https_proxy': 'http://127.0.0.1:7897',
        'http_proxy': 'http://127.0.0.1:7897',
        'no_proxy': '127.0.0.1,localhost',
      }).createHttpClient(null);
      addTearDown(() => client.close(force: true));
      expect(
        HttpClient.findProxyFromEnvironment(
          Uri.parse('https://monster-siren.hypergryph.com'),
          environment: {'https_proxy': 'http://127.0.0.1:7897'},
        ),
        'PROXY 127.0.0.1:7897',
      );
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      request.headers.set('user-agent', fhRadioStudioUserAgent('SirenLibrary'));
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(fhRadioStudioUserAgent().codeUnits.every((v) => v < 128), isTrue);
    },
  );
  test(
    'batch caches, skips completed waveforms, continues errors and preserves timing file',
    () async {
      final f = await fixture();
      final tracks = [
        for (var i = 0; i < 3; i++) song('${f.dir.path}/sources/batch-$i.wav'),
      ];
      for (final t in tracks) {
        File(t.source).writeAsBytesSync([1]);
      }
      final timing = File('${f.dir.path}/analysis/track_timing.json')
        ..writeAsStringSync('{"schema_version":2,"tracks":[]}');
      final original = timing.readAsBytesSync();
      await WaveformCache.write(f.dir.path, tracks[0].source, payload);
      var calls = 0;
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            f.container.read(sharedPreferencesProvider),
          ),
          batchWaveformLoaderProvider.overrideWithValue((
            project,
            repoRoot,
            source,
            token,
          ) async {
            calls++;
            if (source == tracks[1].source) {
              throw const FormatException('bad audio');
            }
            await WaveformCache.write(project, source, payload);
          }),
        ],
      );
      addTearDown(c.dispose);
      await c.read(waveformBatchProvider.notifier).start([
        ...tracks,
        tracks[2],
      ]);
      final state = c.read(waveformBatchProvider);
      expect(state.done, 3);
      expect(state.total, 3);
      expect(state.cached, 1);
      expect(state.errors.length, 1);
      expect(calls, 2);
      expect(state.running, isFalse);
      expect(timing.readAsBytesSync(), original);
      await c.read(waveformBatchProvider.notifier).start(tracks);
      expect(c.read(waveformBatchProvider).cached, 2);
      expect(calls, 3);
      expect(timing.readAsBytesSync(), original);
    },
  );
  test('batch cancellation stops before the next song', () async {
    final f = await fixture();
    final started = Completer<void>(), finish = Completer<void>();
    var calls = 0;
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          f.container.read(sharedPreferencesProvider),
        ),
        batchWaveformLoaderProvider.overrideWithValue((
          project,
          repoRoot,
          source,
          token,
        ) async {
          calls++;
          started.complete();
          await finish.future;
          expect(token.isCancelled, isTrue);
        }),
      ],
    );
    addTearDown(c.dispose);
    final pending = c.read(waveformBatchProvider.notifier).start([
      song('${f.dir.path}/a.wav'),
      song('${f.dir.path}/b.wav'),
    ]);
    await started.future;
    c.read(waveformBatchProvider.notifier).cancel();
    finish.complete();
    await pending;
    expect(calls, 1);
    expect(c.read(waveformBatchProvider).cancelled, isTrue);
    expect(c.read(waveformBatchProvider).running, isFalse);
  });
  test('Siren option defaults off and preserves an explicit opt in', () async {
    final f = await fixture();
    final c = f.container;
    expect(c.read(editorOptionsProvider).sirenEnabled, isFalse);
    c.read(editorOptionsProvider.notifier).update(sirenEnabled: true);
    c.invalidate(editorOptionsProvider);
    expect(c.read(editorOptionsProvider).sirenEnabled, isTrue);
    expect(c.read(editorOptionsProvider).manualOnly, isFalse);
  });
  testWidgets('browse controls fill wide lists and offer one artist sort', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SongBrowseControls(
            value: const SongBrowse(),
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('歌手名称'), findsNothing);
    final controls = find.byType(DropdownButton<String>);
    final right = tester.getTopRight(controls.last).dx;
    expect(right, greaterThan(750));
    expect(tester.takeException(), isNull);
  });
  testWidgets('sync and expansion controls share one row at desktop widths', (
    tester,
  ) async {
    final f = await fixture();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: EditorOptionsControls()),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('PL 自动同步 TL')).dy,
      tester.getTopLeft(find.text('电台扩容 · 实验功能')).dy,
    );
    expect(tester.takeException(), isNull);
  });
}
