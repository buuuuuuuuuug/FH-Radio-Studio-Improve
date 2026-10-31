import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/deployment_preview.dart';
import 'package:fh_radio_studio/core/game_deployment_target.dart';
import 'package:fh_radio_studio/screens/dashboard.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/deployment_file_list.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'studio_v18_workflow_test.dart' as fixtures;

DeploymentPreview plan(GameDeploymentTarget target, {int extra = 0}) {
  final root = 'D:/Game/${target.directoryName}';
  DeploymentFilePreview file(
    String name,
    String description,
    String category,
  ) => DeploymentFilePreview(
    fileName: name,
    destination: '$root/audio/$name',
    relativePath: '${target.directoryName}/audio/$name',
    description: description,
    category: category,
    sizeBytes: 12345,
  );
  return DeploymentPreview(
    changedFilesOnly: true,
    omittedUnchangedCount: 15,
    writes: [
      file(
        'R9_Stingers_JP.assets.bank',
        '第 9 电台 · 日语台呼，应用 16 条自建音频。',
        'resource',
      ),
      file('RadioInfo_JP.xml', '日语电台配置，包含歌单、台呼标记和衔接时间。', 'resource'),
      file('JP.zip', '用于简体中文显示、日语语音的语言文本。', 'resource'),
      file('UserPreferredLang', '设置游戏使用的语音语言：日语。', 'setting'),
      file(
        'last_applied_package_manifest.json',
        '记录本次写入结果，供之后校验和恢复使用。',
        'record',
      ),
      for (var i = 0; i < extra; i++)
        file('Extra_$i.xml', '其他需要写入的电台配置。', 'resource'),
    ],
  );
}

Future<void> showPreview(
  WidgetTester tester,
  DeploymentPreviewLoader loader, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = await fixtures.fixture();
  final state = c
      .read(studioProvider)
      .copyWith(
        gameRunning: false,
        lastPackageDir: 'D:/Project/packages/current',
        lastPackageSummary: const PackageArtifactSummary(
          radio: 9,
          station: 'Opus',
          bankName: 'R9_Stingers_JP.assets.bank',
          musicCount: 0,
          bankSlots: 16,
          playlistMode: 'preserve',
          skipBank: false,
          runtimeVerified: false,
          sourceLang: 'CHS',
          targetLang: 'JP',
          previewTracks: [],
          assignments: [],
        ),
      );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(
        body: deploymentDialogForTesting(state, loadFiles: loader),
      ),
    ),
  );
  await tester.pump();
}

Future<void> acknowledge(WidgetTester tester) async {
  for (final label in ['写入的是最近准备好的电台包', '理解这会修改本地游戏文件，上次写入指纹会在成功后更新']) {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
  }
}

RmButton confirm(WidgetTester tester) =>
    tester.widget<RmButton>(find.widgetWithText(RmButton, '确认写入'));

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final width in [1280.0, 820.0, 620.0]) {
    testWidgets('write list fits at $width and stacks only when necessary', (
      tester,
    ) async {
      await showPreview(
        tester,
        (target, excluded) async => plan(target),
        size: Size(width, 900),
      );
      await tester.pumpAndSettle();
      final files = find.byKey(const ValueKey('deploy-files-panel'));
      final checks = find.byKey(const ValueKey('deploy-choice-mediapc'));
      if (width == 1280) {
        expect(
          tester.getTopLeft(files).dx,
          greaterThan(tester.getTopLeft(checks).dx),
        );
        expect(
          tester.getTopLeft(files).dy,
          lessThan(tester.getBottomRight(checks).dy),
        );
      } else {
        expect(
          tester.getTopLeft(files).dy,
          greaterThan(tester.getBottomRight(checks).dy),
        );
      }
      expect(find.text('本次写入文件'), findsOneWidget);
      expect(find.text('游戏资源 · 3 个文件'), findsOneWidget);
      expect(find.text('语言设置与工具记录 · 2 个文件'), findsOneWidget);
      final list = tester.widget<DeploymentFileList>(files);
      expect(
        list.preview!.writes.map((f) => f.fileName),
        containsAll([
          'R9_Stingers_JP.assets.bank',
          'RadioInfo_JP.xml',
          'JP.zip',
          'UserPreferredLang',
          'last_applied_package_manifest.json',
        ]),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'confirmation waits for list and ignores stale target responses',
    (tester) async {
      final requests = <(GameDeploymentTarget, Completer<DeploymentPreview>)>[];
      await showPreview(tester, (target, excluded) {
        final pending = Completer<DeploymentPreview>();
        requests.add((target, pending));
        return pending.future;
      });
      await acknowledge(tester);
      expect(confirm(tester).onPressed, isNull);
      requests.first.$2.complete(plan(GameDeploymentTarget.mediapc));
      await tester.pumpAndSettle();
      expect(confirm(tester).onPressed, isNotNull);
      await tester.tap(find.text('media（覆盖原文件）'));
      await tester.pump();
      expect(confirm(tester).onPressed, isNull);
      await tester.tap(find.text('mediapc（默认）'));
      await tester.pump();
      expect(requests, hasLength(3));
      requests.last.$2.complete(plan(GameDeploymentTarget.mediapc));
      await tester.pumpAndSettle();
      requests[1].$2.complete(plan(GameDeploymentTarget.media));
      await tester.pumpAndSettle();
      final files = tester.widget<DeploymentFileList>(
        find.byType(DeploymentFileList),
      );
      expect(files.preview!.writes.first.destination, contains('/mediapc/'));
      expect(confirm(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed list blocks confirmation and can be retried', (
    tester,
  ) async {
    var attempts = 0;
    await showPreview(tester, (target, excluded) async {
      if (attempts++ == 0) {
        throw const FormatException('RadioInfo_JP.xml 已变化，请重新构建。');
      }
      return plan(target);
    });
    await tester.pumpAndSettle();
    await acknowledge(tester);
    expect(find.text('无法读取写入清单'), findsOneWidget);
    expect(find.text('RadioInfo_JP.xml 已变化，请重新构建。'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(confirm(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long write list scrolls without moving confirmation footer', (
    tester,
  ) async {
    await showPreview(
      tester,
      (target, excluded) async => plan(target, extra: 35),
      size: const Size(1280, 720),
    );
    await tester.pumpAndSettle();
    final footer = find.widgetWithText(RmButton, '确认写入');
    final before = tester.getRect(footer);
    final panel = find.byKey(const ValueKey('deploy-files-panel'));
    final scroll = find
        .descendant(of: panel, matching: find.byType(Scrollable))
        .first;
    await tester.drag(scroll, const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(tester.getRect(footer), before);
    final state = tester.state<ScrollableState>(scroll);
    expect(state.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
  testWidgets('file selection is passed to loader; all-off cannot confirm', (
    tester,
  ) async {
    final requests = <Set<String>>[];
    await showPreview(tester, (target, excluded) async {
      requests.add(Set.of(excluded));
      return plan(target);
    });
    await tester.pumpAndSettle();
    await acknowledge(tester);
    const id = 'mediapc/audio/R9_Stingers_JP.assets.bank';
    await tester.tap(find.byKey(const ValueKey('deploy-select-$id')));
    await tester.pumpAndSettle();
    expect(requests.last, contains(id));
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('deploy-select-$id')))
          .value,
      false,
    );
    // Selecting all, then clearing all, is stable and does not discard list rows.
    await tester.tap(
      find
          .descendant(
            of: find.byType(DeploymentFileList),
            matching: find.byType(Checkbox),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(DeploymentFileList),
            matching: find.byType(Checkbox),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(requests.last.length, 5);
    expect(confirm(tester).onPressed, isNull);
    expect(find.text('R9_Stingers_JP.assets.bank'), findsOneWidget);
    expect(find.textContaining('D:/Game'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
