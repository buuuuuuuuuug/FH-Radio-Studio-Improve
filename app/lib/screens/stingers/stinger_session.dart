import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/fh_radio_studio_cli.dart';

/// One project-local worker. Requests are serialized in the CLI and use its lock.
class StingerSession {
  StingerSession(
    this.cli,
    this.project,
    this.game, {
    this.command = 'stingers',
  });
  final FhRadioStudioCli cli;
  final String project, game;
  final String command;
  Future<void> warmUp() => _start();
  Process? _process;
  Future<void>? _starting;
  int _next = 0;
  bool _disposed = false;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  Future<void> _start() async {
    if (_disposed) throw const FormatException('已关闭音频编辑。');
    if (_process != null) return;
    if (_starting != null) return _starting;
    _starting = () async {
      final tools = cli.uvRuntime.audioToolsDir;
      final process = await cli.startBaseWorker([
        command,
        'serve',
        '--project-dir',
        project,
        '--game-dir',
        game,
        '--ffmpeg',
        '$tools/ffmpeg/ffmpeg.exe',
        '--vgmstream-cli',
        '$tools/vgmstream/vgmstream-cli.exe',
      ]);
      if (_disposed) {
        process.kill();
        throw const FormatException('已关闭音频编辑。');
      }
      _process = process;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!identical(_process, process) || line.trim().isEmpty) return;
              try {
                final message = jsonDecode(line);
                if (message is! Map ||
                    message['id'] is! int ||
                    (message['error'] == null && message['result'] is! Map)) {
                  throw const FormatException('音频处理返回了无效响应，请重试。');
                }
                final result = message['error'] == null
                    ? Map<String, dynamic>.from(message['result'] as Map)
                    : null;
                final future = _pending.remove(message['id']);
                if (message['error'] != null) {
                  future?.completeError(FormatException('${message['error']}'));
                } else {
                  future?.complete(result!);
                }
              } on Object {
                _disconnect(process, const FormatException('音频处理返回了无效响应，请重试。'));
              }
            },
            onError: (Object error) => _disconnect(process, error),
            onDone: () =>
                _disconnect(process, const FormatException('音频处理已停止，请重试。')),
          );
      unawaited(
        process.stderr.drain<void>().catchError((Object error) {
          _disconnect(process, error);
        }),
      );
      unawaited(
        process.stdin.done.then<void>(
          (_) {},
          onError: (Object error) {
            _disconnect(process, error);
          },
        ),
      );
      unawaited(
        process.exitCode.then((_) {
          if (identical(_process, process)) {
            _process = null;
            _fail(const FormatException('音频处理已停止，请重试。'));
          }
        }),
      );
    }();
    try {
      await _starting;
    } finally {
      _starting = null;
    }
  }

  void _disconnect(Process process, Object error) {
    if (!identical(_process, process)) return;
    _process = null;
    process.kill();
    _fail(error);
  }

  void _fail(Object error) {
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
  }

  Future<Map<String, dynamic>> call(
    String action, {
    String locale = 'JP',
    bool gameView = false,
    String? slot,
    String? asset,
    List<String> paths = const [],
    Map<String, dynamic>? input,
  }) async {
    await _start();
    final process = _process;
    if (_disposed || process == null) {
      throw const FormatException('音频处理已停止，请重试。');
    }
    final id = ++_next;
    final future = Completer<Map<String, dynamic>>();
    _pending[id] = future;
    try {
      process.stdin.writeln(
        jsonEncode({
          'id': id,
          'action': action,
          'locale': locale,
          'current_game': gameView,
          'slot': slot,
          'asset_id': asset,
          'paths': paths,
          'input': input,
        }),
      );
    } on Object catch (error) {
      _pending.remove(id);
      _disconnect(process, error);
      rethrow;
    }
    return future.future;
  }

  void dispose() {
    _disposed = true;
    final process = _process;
    _process = null;
    if (process != null) {
      unawaited(
        process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      );
    }
    process?.kill();
    _fail(const FormatException('已关闭音频编辑。'));
  }
}
