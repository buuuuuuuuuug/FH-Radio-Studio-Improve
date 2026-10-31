import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/screens/stingers/stinger_session.dart';

class _Process extends Fake implements Process {
  _Process() {
    input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => requests.add(Map<String, dynamic>.from(jsonDecode(line))),
        );
  }
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final exited = Completer<int>();
  final requests = <Map<String, dynamic>>[];
  late final sink = IOSink(input.sink);
  bool killed = false;
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => exited.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) exited.complete(1);
    if (!output.isClosed) unawaited(output.close());
    return true;
  }

  void line(Object response) => output.add(utf8.encode('$response\n'));
  void result(int request, Object value) =>
      line(jsonEncode({'id': requests[request]['id'], 'result': value}));
}

class _Cli extends FhRadioStudioCli {
  _Cli(this.workers) : super(repoRoot: Directory.current.parent.path);
  final List<_Process> workers;
  var starts = 0;
  @override
  Future<Process> startBaseWorker(List<String> args) async => workers[starts++];
}

Future<void> _sent(_Process process, int count) async {
  for (var i = 0; i < 50 && process.requests.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(process.requests, hasLength(count));
}

void main() {
  test(
    'malformed worker stdout fails every pending request and retry restarts',
    () async {
      final broken = _Process(), recovered = _Process();
      final cli = _Cli([broken, recovered]);
      final session = StingerSession(cli, 'project', 'game');
      addTearDown(session.dispose);
      final first = session.call('asset-info', asset: 'a');
      final second = session.call('asset-info', asset: 'b');
      final errors = Future.wait([
        expectLater(first, throwsFormatException),
        expectLater(second, throwsFormatException),
      ]);
      await _sent(broken, 2);
      broken.line('not a JSON response');
      await errors;
      expect(broken.killed, isTrue);
      final retry = session.call('asset-info', asset: 'a');
      await _sent(recovered, 1);
      recovered.result(0, {'path': 'a.wav'});
      expect(await retry, {'path': 'a.wav'});
      expect(cli.starts, 2);
    },
  );

  test(
    'a structured operation error does not destroy the reusable worker',
    () async {
      final worker = _Process(), cli = _Cli([]);
      cli.workers.add(worker);
      final session = StingerSession(cli, 'project', 'game');
      addTearDown(session.dispose);
      final first = session.call('asset-info', asset: 'missing');
      final error = expectLater(first, throwsFormatException);
      await _sent(worker, 1);
      worker.line(
        jsonEncode({'id': worker.requests[0]['id'], 'error': '素材不存在'}),
      );
      await error;
      final second = session.call('asset-info', asset: 'present');
      await _sent(worker, 2);
      worker.result(1, {'path': 'present.wav'});
      expect(await second, {'path': 'present.wav'});
      expect(cli.starts, 1);
      expect(worker.killed, isFalse);
    },
  );

  test(
    'closed worker output releases waiters instead of leaving a hanging request',
    () async {
      final worker = _Process();
      final session = StingerSession(_Cli([worker]), 'project', 'game');
      addTearDown(session.dispose);
      final pending = session.call('asset-info');
      final error = expectLater(pending, throwsFormatException);
      await _sent(worker, 1);
      await worker.output.close();
      await error;
      expect(worker.killed, isTrue);
    },
  );
}
