import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:fh_radio_studio/core/voice_audition.dart';

class _Streams extends Fake implements PlayerStream {
  _Streams(this.durations);
  final Stream<Duration> durations;
  @override
  Stream<Duration> get duration => durations;
}

class _Player extends Fake implements Player {
  final durations = StreamController<Duration>.broadcast();
  PlayerState value = const PlayerState();
  int plays = 0, opens = 0;
  Duration? sought;
  @override
  PlayerState get state => value;
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerStream get stream => _Streams(durations.stream);
  @override
  Future<void> pause() async {}
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    final media = playable as Media;
    final duration = media.uri.endsWith('broken.wav')
        ? Duration.zero
        : const Duration(seconds: 2);
    value = PlayerState(playlist: Playlist([media]), duration: duration);
    if (duration > Duration.zero) durations.add(duration);
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration position) async {
    sought = position;
  }

  @override
  Future<void> play() async {
    plays++;
  }
}

void main() {
  test(
    'cancelling missing metadata releases the next audition and its listener',
    () async {
      final player = _Player();
      addTearDown(player.durations.close);
      var current = true;
      final stalled = prepareVoiceAudition(
        player,
        'broken.wav',
        isCurrent: () => current,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(player.durations.hasListener, isTrue);
      current = false;
      await stalled.timeout(const Duration(milliseconds: 250));
      expect(player.durations.hasListener, isFalse);
      expect(player.plays, 0);
      await startVoiceAudition(
        player,
        'ready.wav',
      ).timeout(const Duration(milliseconds: 250));
      expect(player.plays, 1);
      expect(player.sought, Duration.zero);
    },
  );

  test(
    'an exact EOF start restarts without a ten-second readiness stall',
    () async {
      final player = _Player();
      addTearDown(player.durations.close);
      await startVoiceAudition(player, 'ready.wav', start: 2);
      expect(player.sought, Duration.zero);
      expect(player.plays, 1);
    },
  );

  test(
    'invalid positions, empty ranges and nonfinite volume never reach the output',
    () async {
      final player = _Player();
      addTearDown(player.durations.close);
      for (final start in [-.1, double.nan, double.infinity]) {
        await expectLater(
          startVoiceAudition(player, 'ready.wav', start: start),
          throwsArgumentError,
        );
      }
      for (final end in [0.0, double.nan, double.infinity]) {
        await expectLater(
          startVoiceAudition(player, 'ready.wav', end: end),
          throwsArgumentError,
        );
      }
      await expectLater(
        startVoiceAudition(player, 'ready.wav', gainDb: double.nan),
        throwsArgumentError,
      );
      expect(player.opens, 0);
      expect(player.plays, 0);
    },
  );
}
