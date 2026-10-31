import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/core/playlist_action_errors.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'editor_playlist_upgrade_test.dart' as fixture;
import 'studio_v21_workflow_test.dart' as helpers;

class FailingSave extends PlaylistPlanController {
  FailingSave(super.ref);
  @override
  void save() => throw const FileSystemException(
    'write failed',
    'playlist_plan.json',
    OSError('disk full', 112),
  );
}

class ReadyStudio extends StudioController {
  ReadyStudio(super.prefs, StudioState ready) {
    state = ready;
  }
}

class FailingPreview extends StudioController {
  FailingPreview(super.prefs, StudioState ready) {
    state = ready;
  }
  @override
  PackageBuildLoudnessPreview buildPackageLoudnessPreview() =>
      throw const FileSystemException(
        'write failed',
        'project.json',
        OSError('disk full', 112),
      );
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  test(
    'storage errors identify full disks without exposing raw exceptions',
    () {
      for (final code in [28, 39, 112]) {
        expect(
          playlistActionFailure(
            '保存播放列表',
            FileSystemException('write', 'file', OSError('full', code)),
          ),
          contains('磁盘空间不足'),
        );
      }
      expect(
        playlistActionFailure('保存播放列表', const FormatException('数据无效')),
        contains('数据无效'),
      );
    },
  );
  testWidgets(
    'failed playlist save shows a failure rather than a success message',
    (t) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final semantics = t.ensureSemantics();

      final f = await fixture.fixture();
      final prefs = f.container.read(sharedPreferencesProvider);
      final ready = f.container.read(studioProvider);
      final isolated = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => ReadyStudio(prefs, ready)),
          playlistPlanProvider.overrideWith((ref) => FailingSave(ref)),
        ],
      );
      addTearDown(isolated.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: isolated,
          child: helpers.app(const PlaylistScreen()),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('保存播放列表'));
      await t.pumpAndSettle();
      expect(find.textContaining('保存播放列表失败：磁盘空间不足'), findsOneWidget);
      expect(find.textContaining('歌曲分配与顺序已保存'), findsNothing);
      semantics.dispose();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('build preflight exceptions produce a visible notice', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = await fixture.fixture();
    final prefs = f.container.read(sharedPreferencesProvider);
    final ready = f.container.read(studioProvider);
    final isolated = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => FailingPreview(prefs, ready)),
        playlistPlanProvider.overrideWith(
          (ref) =>
              PlaylistPlanController(ref)
                ..replaceWith(const PlaylistPlan.empty()),
        ),
      ],
    );
    addTearDown(isolated.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: isolated,
        child: helpers.app(const PlaylistScreen()),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('构建准备包').first);
    await t.pumpAndSettle();
    expect(find.text('构建前保存修改？'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('build-unsaved-save')));
    await t.pumpAndSettle();
    expect(find.textContaining('构建准备包失败：磁盘空间不足'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
