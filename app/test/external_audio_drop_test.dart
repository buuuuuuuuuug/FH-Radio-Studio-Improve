import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/widgets/external_audio_drop_target.dart';

Future<bool> drop(WidgetTester tester, Offset point, List<String> paths) async {
  return event(tester, 'filesDropped', point, paths);
}

Future<bool> event(
  WidgetTester tester,
  String method,
  Offset point,
  List<String> paths,
) async {
  const codec = StandardMethodCodec();
  final reply = Completer<ByteData?>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'fh_radio_studio/file_drop',
    codec.encodeMethodCall(
      MethodCall(method, {'x': point.dx, 'y': point.dy, 'paths': paths}),
    ),
    reply.complete,
  );
  return codec.decodeEnvelope((await reply.future)!) as bool;
}

void main() {
  testWidgets('external files use the smallest visible enabled target', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExternalAudioDropTarget(
            onDrop: (paths) async => calls.add('pool:${paths.join(',')}'),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 220,
                height: 80,
                child: ExternalAudioDropTarget(
                  onDrop: (paths) async => calls.add('row:${paths.join(',')}'),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      await drop(tester, const Offset(20, 20), ['D:/声/1.wav', 'D:/声/2.wav']),
      isTrue,
    );
    expect(calls, ['row:D:/声/1.wav,D:/声/2.wav']);
    expect(await drop(tester, const Offset(400, 200), ['D:/3.wav']), isTrue);
    expect(calls.last, 'pool:D:/3.wav');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dialog prevents files reaching an underlying workspace', (
    tester,
  ) async {
    var imports = 0;
    late BuildContext route;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            route = context;
            return Scaffold(
              body: ExternalAudioDropTarget(
                onDrop: (_) async => imports++,
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );
    unawaited(
      showDialog<void>(
        context: route,
        builder: (_) => const Dialog(child: SizedBox(width: 100, height: 100)),
      ),
    );
    await tester.pumpAndSettle();
    expect(await drop(tester, const Offset(10, 10), ['D:/audio.wav']), isFalse);
    expect(imports, 0);
    expect(tester.takeException(), isNull);
  });
}
