import 'package:flutter/material.dart';
import '../core/deployment_preview.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_chip.dart';

class DeploymentFileList extends StatelessWidget {
  const DeploymentFileList({
    super.key,
    required this.preview,
    required this.loading,
    required this.error,
    required this.onReload,
    this.excludedFiles = const {},
    this.onToggle,
    this.onSelectAll,
    this.scrollable = true,
  });
  final DeploymentPreview? preview;
  final bool loading, scrollable;
  final String? error;
  final VoidCallback onReload;
  final Set<String> excludedFiles;
  final ValueChanged<String>? onToggle;
  final ValueChanged<bool>? onSelectAll;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm, plan = preview;
    final selected =
        plan?.writes.where((f) => !excludedFiles.contains(f.id)).length ?? 0;
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(
        label,
        style: RmText.sans(11, color: rm.fg3, weight: FontWeight.w600),
      ),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Text(
            '无法读取写入清单',
            style: RmText.sans(12, color: rm.danger, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(error!, style: RmText.sans(11, color: rm.fg2, height: 1.4)),
          Align(
            alignment: Alignment.centerLeft,
            child: RmButton(
              label: '重试',
              onPressed: onReload,
              size: RmButtonSize.sm,
            ),
          ),
        ],
        if (plan != null) ...[
          for (final issue in plan.selectionIssues)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                issue,
                style: RmText.sans(11, color: rm.danger, height: 1.4),
              ),
            ),
          heading('游戏资源 · ${plan.resourceCount} 个文件'),
          if (plan.resourceCount == 0)
            Text('本次没有需要写入的游戏资源。', style: RmText.sans(11, color: rm.fg3)),
          for (final file in plan.writes.where((f) => f.category == 'resource'))
            _FileRow(
              file,
              selected: !excludedFiles.contains(file.id),
              onToggle: onToggle,
            ),
          if (plan.auxiliaryCount > 0) ...[
            heading('语言设置与工具记录 · ${plan.auxiliaryCount} 个文件'),
            for (final file in plan.writes.where(
              (f) => f.category != 'resource',
            ))
              _FileRow(
                file,
                selected: !excludedFiles.contains(file.id),
                onToggle: onToggle,
              ),
          ],
          if (plan.removals.isNotEmpty) ...[
            heading('同时移除的旧覆盖 · ${plan.removals.length} 个文件'),
            for (final file in plan.removals) _FileRow(file, selected: true),
          ],
          if (plan.changedFilesOnly && plan.omittedUnchangedCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '已省略 ${plan.omittedUnchangedCount} 个与游戏一致的资源文件。',
                style: RmText.sans(10.5, color: rm.fg3),
              ),
            ),
        ] else if (loading)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text('正在读取写入清单…', style: RmText.sans(12, color: rm.fg3)),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: scrollable ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '本次写入文件',
                  style: RmText.sans(13, color: rm.fg, weight: FontWeight.w600),
                ),
              ),
              if (plan != null)
                RmChip(
                  label: '已选 $selected / ${plan.writes.length}',
                  dense: true,
                  variant: RmChipVariant.accent,
                ),
              const SizedBox(width: 6),
              RmButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                tooltip: '重新读取清单',
                onPressed: loading ? null : onReload,
              ),
            ],
          ),
          Row(
            children: [
              Checkbox(
                value: plan == null || selected == 0
                    ? false
                    : selected == plan.writes.length
                    ? true
                    : null,
                tristate: true,
                activeColor: rm.accent.base,
                visualDensity: VisualDensity.compact,
                onChanged: plan == null
                    ? null
                    : (_) => onSelectAll?.call(selected != plan.writes.length),
              ),
              Text('全选', style: RmText.sans(11.5, color: rm.fg2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '取消勾选即可跳过；以下为相对写入位置。',
                  style: RmText.sans(10.5, color: rm.fg3),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 2,
            child: loading
                ? LinearProgressIndicator(
                    color: rm.accent.base,
                    backgroundColor: rm.raised,
                  )
                : null,
          ),
          const SizedBox(height: 4),
          if (scrollable)
            Expanded(child: SingleChildScrollView(child: content))
          else
            content,
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow(this.file, {required this.selected, this.onToggle});
  final DeploymentFilePreview file;
  final bool selected;
  final ValueChanged<String>? onToggle;
  String get _size {
    final bytes = file.sizeBytes;
    if (bytes == null) return '自动生成';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm, remove = file.operation == 'remove';
    final path = file.relativePath.replaceAll('\\', '/');
    final slash = path.lastIndexOf('/');
    final directory = slash < 0 ? '' : path.substring(0, slash + 1);
    return Container(
      key: ValueKey('deploy-file-${file.category}-${file.relativePath}'),
      margin: const EdgeInsets.only(bottom: 5),
      decoration: BoxDecoration(
        color: selected ? rm.raised : rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(RmTokens.rMd),
        onTap: onToggle == null ? null : () => onToggle!(file.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 6, 10, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!remove)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Checkbox(
                    key: ValueKey('deploy-select-${file.id}'),
                    value: selected,
                    activeColor: rm.accent.base,
                    visualDensity: VisualDensity.compact,
                    onChanged: onToggle == null
                        ? null
                        : (_) => onToggle!(file.id),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.remove_circle_outline,
                    size: 16,
                    color: rm.danger,
                  ),
                ),
              const SizedBox(width: 5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            file.fileName,
                            style: RmText.mono(
                              11,
                              color: selected ? rm.fg : rm.fg3,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(_size, style: RmText.mono(9.5, color: rm.fg3)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      file.description,
                      style: RmText.sans(
                        11,
                        color: remove ? rm.danger : rm.fg2,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 3),
                    SelectableText(
                      directory.isEmpty
                          ? file.pathBase
                          : '${file.pathBase} / $directory',
                      style: RmText.mono(9.5, color: rm.fg3, height: 1.25),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
