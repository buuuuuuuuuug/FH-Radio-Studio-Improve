import 'setting_toggle_row.dart';
import 'feature_tour.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../state/router.dart';
import '../state/playlist_catalog_state.dart';
import 'timing_dialog_frame.dart';
import 'rm_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/editor_options.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';

class EditorOptionsControls extends ConsumerWidget {
  const EditorOptionsControls({super.key, this.analysisControl});
  final Widget? analysisControl;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(editorOptionsProvider);
    final controller = ref.read(editorOptionsProvider.notifier);
    final rm = context.rm;
    Widget option(
      String title,
      String description,
      bool value,
      ValueChanged<bool> change,
    ) {
      return SettingToggleRow(
        title: title,
        description: description,
        value: value,
        onChanged: change,
      );
    }

    return Column(
      children: [
        Divider(height: 1, color: rm.border),
        LayoutBuilder(
          builder: (context, constraints) {
            final sync = option(
              'PL 自动同步 TL',
              'TL 比赛中循环，PL 冲线后循环；同步起止时间与确认状态',
              options.syncPostLoop,
              (v) => controller.update(syncPostLoop: v),
            ).tourAnchor('sync');
            final manual =
                (analysisControl == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: analysisControl,
                      )) ??
                option(
                  '无 AI 处理模式',
                  '只加载波形，使用手动精调',
                  options.manualOnly,
                  (v) => controller.update(manualOnly: v),
                );
            final expansion = option(
              '电台扩容 · 实验功能',
              '允许超过原版曲目数量；使用分场景编辑时必须开启',
              options.expansionEnabled,
              (v) {
                if (!controller.update(expansionEnabled: v)) {
                  showDialog<void>(
                    context: context,
                    builder: (dialogContext) => TimingDialogFrame(
                      title: '暂时不能关闭电台扩容',
                      busy: false,
                      width: 500,
                      body: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '请先关闭分场景编辑；如有超出原版容量的电台，还需减少曲目：',
                            style: RmText.sans(12, color: rm.fg2),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: rm.warnBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: rm.warn.withAlpha(100)),
                            ),
                            child: Text(
                              controller.expansionOverflow().join('\n'),
                              style: RmText.mono(12, color: rm.warn),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '现有歌曲与顺序不会自动删除。',
                            style: RmText.sans(11.5, color: rm.fg3),
                          ),
                        ],
                      ),
                      actions: [
                        RmButton(
                          label: '知道了',
                          onPressed: () => Navigator.pop(dialogContext),
                        ),
                        RmButton(
                          label: '前往播放列表',
                          variant: RmButtonVariant.primary,
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            ref
                                    .read(playlistCatalogViewProvider.notifier)
                                    .state =
                                PlaylistCatalogView.package;
                            context.go(RmRoutes.playlist);
                          },
                        ),
                      ],
                    ),
                  );
                }
              },
            ).tourAnchor('expansion');
            if (constraints.maxWidth < 900) {
              return Column(
                children: [
                  manual,
                  Divider(height: 1, color: rm.border),
                  if (constraints.maxWidth < 600) ...[
                    sync,
                    Divider(height: 1, color: rm.border),
                    expansion,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: sync),
                        Container(width: 1, height: 64, color: rm.border),
                        Expanded(child: expansion),
                      ],
                    ),
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 2, child: manual),
                  VerticalDivider(width: 1, color: rm.border),
                  Expanded(child: sync),
                  VerticalDivider(width: 1, color: rm.border),
                  Expanded(child: expansion),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
