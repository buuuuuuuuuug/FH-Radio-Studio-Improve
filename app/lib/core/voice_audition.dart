import 'package:media_kit/media_kit.dart';
import 'dart:async';
import 'dart:math' as math;

final _auditionQueues = Expando<Future<void>>();

/// Load and position a material while its editor is opening. No samples are
/// played, and a later play click can reuse the prepared decoder/output.
Future<void> prepareVoiceAudition(
  Player player,
  String path, {
  bool Function()? isCurrent,
  double start = 0,
  double gainDb = 0,
}) => _queueVoiceAudition(
  player,
  path,
  isCurrent: isCurrent,
  start: start,
  gainDb: gainDb,
  play: false,
);

/// The decoder may report EOF while the audio output still has queued samples.
/// Keep transport state alive until the native playhead drains that tail.
Future<void> waitForVoiceTail(
  Player player,
  double end, {
  bool Function()? isCurrent,
}) async {
  final native = player.platform;
  if (native is! NativePlayer) return;
  final position = double.tryParse(await native.getProperty('time-pos'));
  if (position == null) return;
  // The output clock itself stops on its final update interval. Waiting for an
  // exact end timestamp can hang even after all samples have played. Drain the
  // remaining real-time duration instead; auditions always run at rate 1.
  final remaining = Duration(
    microseconds: ((end - position).clamp(0.0, 1.0) * 1e6).ceil(),
  );
  final clock = Stopwatch()..start();
  while (clock.elapsed < remaining) {
    if (isCurrent?.call() == false) return;
    final left = remaining - clock.elapsed;
    await Future<void>.delayed(
      left > const Duration(milliseconds: 25)
          ? const Duration(milliseconds: 25)
          : left,
    );
  }
}

/// A voice audition always starts paused at zero. It must never inherit the
/// song editor's race/loop end points or begin playing before preparation ends.
Future<void> startVoiceAudition(
  Player player,
  String path, {
  bool Function()? isCurrent,
  double start = 0,
  double? end,
  double gainDb = 0,
}) => _queueVoiceAudition(
  player,
  path,
  isCurrent: isCurrent,
  start: start,
  end: end,
  gainDb: gainDb,
  play: true,
);

Future<void> _queueVoiceAudition(
  Player player,
  String path, {
  bool Function()? isCurrent,
  double start = 0,
  double? end,
  double gainDb = 0,
  required bool play,
}) async {
  final volume = (100 * math.pow(10, gainDb / 20)).toDouble();
  if (!start.isFinite ||
      start < 0 ||
      !gainDb.isFinite ||
      !volume.isFinite ||
      end != null && (!end.isFinite || end <= start)) {
    throw ArgumentError('试听起止时间或音量无效。');
  }
  final previous = _auditionQueues[player] ?? Future<void>.value();
  final task = previous.catchError((Object _) {}).then((_) async {
    if (isCurrent?.call() == false) return;
    await _startVoiceAudition(
      player,
      path,
      isCurrent: isCurrent,
      start: start,
      end: end,
      gainDb: gainDb,
      play: play,
    );
  });
  _auditionQueues[player] = task.catchError((Object _) {});
  await task;
}

Future<void> _startVoiceAudition(
  Player player,
  String path, {
  bool Function()? isCurrent,
  double start = 0,
  double? end,
  double gainDb = 0,
  required bool play,
}) async {
  bool current() => isCurrent?.call() ?? true;
  await player.pause();
  final native = player.platform;
  if (native is NativePlayer) {
    await native.setProperty('ab-loop-a', 'no');
    await native.setProperty('ab-loop-b', 'no');
    await native.setProperty('start', '0');
    await native.setProperty('end', 'none');
    if ((await native.getProperty('af')).isNotEmpty) {
      await native.setProperty('af', '');
    }
  }
  if (!current()) return;
  final media = Media(path);
  final existing = player.state.playlist.medias;
  final opening =
      existing.length != 1 ||
      existing.single.uri != media.uri ||
      player.state.completed ||
      player.state.duration == Duration.zero;
  if (opening) {
    await player.open(media, play: false);
  }
  if (player.state.duration == Duration.zero) {
    if (!await _waitForDuration(player, current)) return;
  }
  if (!current()) return;
  final duration = player.state.duration.inMicroseconds / 1e6;
  // Clicking at the very end of a file should restart it, rather than leave a
  // paused decoder at EOF waiting for a timestamp it can never produce.
  final from = start >= duration ? 0.0 : start;
  final until = end == null ? null : math.min(end, duration);
  if (until != null && until <= from) {
    throw ArgumentError('试听选段不在音频时长内。');
  }
  await player.setPlaylistMode(PlaylistMode.none);
  await player.setRate(1);
  await player.setVolume((100 * math.pow(10, gainDb / 20)).toDouble());
  if (native is NativePlayer && until != null) {
    await native.setProperty('end', until.toStringAsFixed(6));
  }
  // A seek command is asynchronous inside mpv. Unpausing before its restart
  // finishes can discard the initial output. A new file already starts at zero
  // and needs no seek (and no unnecessary output flush).
  if (native is! NativePlayer || !opening || from > 0) {
    if (native is NativePlayer) {
      await native.command(['seek', from.toStringAsFixed(6), 'absolute+exact']);
    } else {
      await player.seek(Duration(microseconds: (from * 1000000).round()));
    }
  }
  if (native is NativePlayer) {
    final clock = Stopwatch()..start();
    while (current()) {
      final seeking = await native.getProperty('seeking');
      final position = double.tryParse(await native.getProperty('time-pos'));
      final output = await native.getProperty('audio-out-params');
      if (seeking == 'no' &&
          position != null &&
          (position - from).abs() < .025 &&
          output.isNotEmpty) {
        break;
      }
      if (clock.elapsed > const Duration(seconds: 10)) {
        throw StateError('音频输出尚未准备完成，请重新试听。');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  if (play && current()) await player.play();
}

/// A closed editor must release its queued preparation even when a missing or
/// invalid file never emits metadata. Dispose the listener on every exit.
Future<bool> _waitForDuration(Player player, bool Function() current) async {
  final result = Completer<bool>();
  void check() {
    if (result.isCompleted) return;
    if (!current()) {
      result.complete(false);
    } else if (player.state.duration > Duration.zero) {
      result.complete(true);
    }
  }

  final subscription = player.stream.duration.listen(
    (duration) {
      if (!result.isCompleted && duration > Duration.zero) {
        result.complete(current());
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  final cancellation = Timer.periodic(
    const Duration(milliseconds: 25),
    (_) => check(),
  );
  final timeout = Timer(const Duration(seconds: 10), () {
    if (!result.isCompleted) {
      result.completeError(TimeoutException('无法读取试听音频时长。'));
    }
  });
  check();
  try {
    return await result.future;
  } finally {
    timeout.cancel();
    cancellation.cancel();
    await subscription.cancel();
  }
}
