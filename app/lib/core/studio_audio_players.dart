import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Keep native mpv instances alive across routes. Destroying a native player
/// waits for decoder threads and can block the UI during Escape navigation.
class StudioAudioPlayers {
  StudioAudioPlayers._();

  static Player? _pool;
  static Player? _editor;
  static Player? _voice;
  static Player? _stinger;
  static Player? _material;
  static String? poolSource;
  static String? editorSource;
  static Player get pool => _pool ??= Player();
  static Player get editor => _editor ??= Player();
  static Player get voice => _voice ??= Player();
  static Player get stinger => _stinger ??= Player();
  static Player get material => _material ??= Player();

  /// Stop existing outputs without constructing unused native players during
  /// the first playback click.
  static Future<void> pauseOthers(Player active) => Future.wait([
    for (final player in [_pool, _editor, _voice, _stinger, _material])
      if (player != null && !identical(player, active)) player.pause(),
  ]);

  static void warmUp() {
    Timer(const Duration(milliseconds: 300), () {
      pool;
      editor;
    });
  }
}
