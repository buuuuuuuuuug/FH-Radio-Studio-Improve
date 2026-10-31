import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/deployment_preview.dart';
import 'package:fh_radio_studio/core/game_deployment_target.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/deployment_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';

const _latest = '清单对应本次已完成的语音准备包';
const _modify = '理解将修改游戏资源，原始快照已保存在工程内';

DeploymentPreview _preview(
  GameDeploymentTarget target,
  Set<String> excluded,
) => DeploymentPreview(
  writes: [
    for (final name in ['VO_DJ_09_JP.assets.bank', 'VO_SatNav_JP.assets.bank'])
      DeploymentFilePreview(
        fileName: name,
        destination: 'D:/Game/${target.directoryName}/audio/FMODBanks/$name',
        relativePath: '${target.directoryName}/audio/FMODBanks/$name',
        description: '日语语音 · 仅替换已编辑的条目。',
        category: 'resource',
        selectionId: name,
        selected: !excluded.contains(name),
        sizeBytes: 1024 * 1024,
      ),
  ],
);

Future<void> _open(
  WidgetTester tester, {
  Size size = const Size(1280, 850),
  DeploymentPreviewLoader? load,
  ValueChanged<DeploymentChoice?>? onResult,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => RmButton(
            label: '打开写入窗口',
            onPressed: () async {
              final result = await showDialog<DeploymentChoice>(
                context: context,
                builder: (_) => DeploymentConfirmationDialog(
                  title: '写入语音准备包',
                  description: '仅写入此页面构建的语音文件，不携带歌曲、台呼或 RadioInfo。',
                  latestConfirmation: _latest,
                  modificationConfirmation: _modify,
                  gameDir: 'D:/Game',
                  gameRunning: false,
                  packageReady: true,
                  loadFiles:
                      load ??
                      (target, excluded) async => _preview(target, excluded),
                ),
              );
              onResult?.call(result);
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.widgetWithText(RmButton, '打开写入窗口'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final size in [const Size(1280, 850), const Size(740, 650)]) {
    testWidgets('voice preflight shares responsive original layout at $size', (
      tester,
    ) async {
      await _open(tester, size: size, onResult: (_) {});
      final files = find.byKey(const ValueKey('deploy-files-panel'));
      final target = find.byKey(const ValueKey('deploy-choice-mediapc'));
      if (size.width > 1000) {
        expect(
          tester.getTopLeft(files).dx,
          greaterThan(tester.getBottomRight(target).dx),
        );
      } else {
        expect(
          tester.getTopLeft(files).dy,
          greaterThan(tester.getBottomRight(target).dy),
        );
      }
      expect(find.text('写入语音准备包'), findsOneWidget);
      expect(find.textContaining('不携带歌曲、台呼或 RadioInfo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(RmButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(DeploymentConfirmationDialog), findsNothing);
    });
  }

  testWidgets('confirmation returns selected target and exclusions only', (
    tester,
  ) async {
    DeploymentChoice? result;
    await _open(tester, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('deploy-target-media')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('deploy-select-VO_SatNav_JP.assets.bank')),
    );
    await tester.pumpAndSettle();
    for (final label in [_latest, _modify]) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(RmButton, '确认写入'));
    await tester.pumpAndSettle();
    expect(result!.target, GameDeploymentTarget.media);
    expect(result!.excludedFiles, {'VO_SatNav_JP.assets.bank'});
    expect(find.byType(DeploymentConfirmationDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('escape and outside click cancel without a write choice', (
    tester,
  ) async {
    final results = <DeploymentChoice?>[];
    await _open(tester, onResult: results.add);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.tap(find.widgetWithText(RmButton, '打开写入窗口'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(results, [null, null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing during preview safely ignores the delayed response', (
    tester,
  ) async {
    final pending = Completer<DeploymentPreview>();
    await _open(tester, settle: false, load: (_, _) => pending.future);
    await tester.tap(find.widgetWithText(RmButton, '取消'));
    await tester.pumpAndSettle();
    pending.complete(_preview(GameDeploymentTarget.mediapc, {}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
