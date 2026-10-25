import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_banner.dart';
import 'rm_button.dart';
import 'timing_dialog_frame.dart';

Future<bool?> showSplitPlaylistConfirmation(
  BuildContext context,
) => showDialog<bool>(
  context: context,
  barrierColor: RmTokens.modalBackdrop,
  builder: (context) => TimingDialogFrame(
    title: '分开编辑漫游和比赛？',
    icon: 'list',
    description: '分别安排 FreeRoam 与 Event 播放列表',
    width: 540,
    busy: false,
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RmBanner(
          key: ValueKey('split-playlist-enable-warning'),
          kind: RmBannerKind.warn,
          title: '分场景编辑 · 实验功能',
          body: '需要保持电台扩容开启。两场景共用一个音频 bank，容量按不同歌曲总数计算。暂不支持一边原版、一边自建，也不能单侧留空。',
        ),
        const SizedBox(height: 16),
        Text(
          '开启后会显示 FreeRoam 和 Event 两张独立列表。FreeRoam 用于开放世界漫游，Event 用于比赛内播放。',
          style: RmText.body(color: context.rm.fg2),
        ),
        const SizedBox(height: 10),
        Text(
          '关闭时选择一张作为统一列表；原来的两张列表会保留，再次打开即可恢复。保存播放列表后会随工程保留。',
          style: RmText.body(color: context.rm.fg3),
        ),
      ],
    ),
    actions: [
      RmButton(label: '取消', onPressed: () => Navigator.of(context).pop(false)),
      RmButton(
        label: '打开',
        variant: RmButtonVariant.primary,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  ),
);

Future<String?> showUnifiedPlaylistSelection(BuildContext context) =>
    showDialog<String>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => TimingDialogFrame(
        title: '关闭后统一使用哪张列表？',
        icon: 'list',
        description: '原来的两张场景列表会保留',
        width: 540,
        busy: false,
        body: Text(
          '所选列表会同时用于漫游和比赛。再次打开分场景编辑，将恢复关闭前的两张列表；统一编辑期间的改动不会覆盖它们。',
          style: RmText.body(color: context.rm.fg2),
        ),
        actions: [
          RmButton(label: '取消', onPressed: () => Navigator.of(context).pop()),
          RmButton(
            label: '统一使用漫游',
            onPressed: () => Navigator.of(context).pop('FreeRoam'),
          ),
          RmButton(
            label: '统一使用比赛',
            variant: RmButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop('Event'),
          ),
        ],
      ),
    );
