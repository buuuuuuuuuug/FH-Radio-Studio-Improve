import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/playlist_action_errors.dart';
import '../screens/playlist/playlist_state.dart';
import '../state/playlist_plan_state.dart';
import '../state/studio_state.dart';
import '../state/editor_options.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'split_playlist_dialog.dart';
import 'feature_tour.dart';
import 'rm_button.dart';
import 'rm_icon.dart';
import 'timing_dialog_frame.dart';

class SplitPlaylistSetting extends ConsumerWidget {
  const SplitPlaylistSetting({super.key, this.showAsSwitch = false});

  final bool showAsSwitch;

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    final project = ref.read(studioProvider).projectDir;
    var keepType = 'FreeRoam';
    if (enabled) {
      if (!ref.read(editorOptionsProvider).expansionEnabled) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => TimingDialogFrame(
            title: '请先开启电台扩容',
            busy: false,
            width: 500,
            body: Text(
              '分场景编辑需要启用电台扩容。请前往概览的基础设置开启，再分别编排漫游与比赛歌单。',
              style: RmText.body(color: context.rm.fg2),
            ),
            actions: [
              RmButton(
                label: '知道了',
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ],
          ),
        );
        return;
      }
      if (await showSplitPlaylistConfirmation(context) != true) return;
    } else if (ref
        .read(effectivePlaylistPlanProvider)
        .hasSplitPlaylistDifferences) {
      final selected = await showUnifiedPlaylistSelection(context);
      if (selected == null) return;
      keepType = selected;
    }
    if (!context.mounted || ref.read(studioProvider).projectDir != project) {
      return;
    }
    try {
      ref
          .read(playlistProvider.notifier)
          .setSplitPlaylistTypes(enabled, keepType: keepType);
    } on Object catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(playlistActionFailure('切换分场景编辑', error))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rm = context.rm;
    final enabled = ref.watch(
      playlistProvider.select((state) => state.splitPlaylistTypes),
    );
    final locked = ref.watch(
      studioProvider.select((state) => state.projectEditingLocked),
    );
    final hasSnapshot = ref.watch(
      effectivePlaylistPlanProvider.select(
        (plan) => plan.splitSnapshot != null,
      ),
    );
    if (showAsSwitch) {
      return Column(
        key: const ValueKey('split-playlist-setting'),
        children: [
          Divider(height: 1, color: rm.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '分场景编辑 · 实验功能',
                        style: RmText.sans(
                          12.5,
                          color: rm.fg,
                          weight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasSnapshot && !enabled
                            ? '开启可恢复保留的漫游与比赛歌单；统一期间的修改不会并入。'
                            : '需要开启电台扩容；分别编排漫游与比赛歌单，关闭时保留两套排布。',
                        style: RmText.sans(11.5, color: rm.fg3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 40,
                  height: 24,
                  child: FittedBox(
                    child: Switch(
                      value: enabled,
                      activeThumbColor: rm.panel,
                      activeTrackColor: rm.accent.base,
                      inactiveThumbColor: rm.fg4,
                      inactiveTrackColor: rm.raised,
                      trackOutlineColor: WidgetStateProperty.all(rm.border),
                      onChanged: locked
                          ? null
                          : (value) => _change(context, ref, value),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ).tourAnchor('split');
    }
    return RmButton(
      key: const ValueKey('split-playlist-setting'),
      label: '分场景编辑',
      leading: RmIcon(
        'list',
        size: 12,
        color: enabled ? rm.accent.base : rm.fg2,
      ),
      foregroundColor: enabled ? rm.accent.base : null,
      tooltip: hasSnapshot && !enabled
          ? '实验功能；点击恢复保留的漫游与比赛列表，统一编辑期间的改动不会并入。'
          : enabled
          ? '实验功能已开启；点击选择关闭后统一使用的列表，原两套排布会保留。'
          : '实验功能；需要开启电台扩容，分别安排漫游与比赛，两场景共用曲库。',
      onPressed: locked ? null : () => _change(context, ref, !enabled),
    ).tourAnchor('split');
  }
}
