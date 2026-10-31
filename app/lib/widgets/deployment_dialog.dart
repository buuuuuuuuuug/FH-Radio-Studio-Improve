import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../core/deployment_preview.dart';
import '../core/game_deployment_target.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'deployment_file_list.dart';
import 'rm_icon.dart';
import 'studio_modal.dart';

/// One preflight flow for song, stinger and independent voice packages.
/// Only returns a selection; writing is handled by the caller after confirmation.
class DeploymentConfirmationDialog extends StatefulWidget {
  const DeploymentConfirmationDialog({
    super.key,
    required this.gameDir,
    required this.gameRunning,
    required this.loadFiles,
    required this.packageReady,
    this.baselineIntegrityBroken = false,
    this.title = '写入游戏前请确认',
    this.description = '选择电台包的写入位置，然后确认下面三项。',
    this.latestConfirmation = '写入的是最近准备好的电台包',
    this.modificationConfirmation = '理解这会修改本地游戏文件，上次写入指纹会在成功后更新',
  });

  final String gameDir, title, description;
  final String latestConfirmation, modificationConfirmation;
  final bool gameRunning, packageReady, baselineIntegrityBroken;
  final DeploymentPreviewLoader loadFiles;

  @override
  State<DeploymentConfirmationDialog> createState() =>
      _DeploymentConfirmationDialogState();
}

class _DeploymentConfirmationDialogState
    extends State<DeploymentConfirmationDialog> {
  GameDeploymentTarget _target = GameDeploymentTarget.mediapc;
  late bool _exit = !widget.gameRunning;
  bool _latest = false, _modify = false, _loading = true;
  int _request = 0;
  DeploymentPreview? _preview;
  final Set<String> _excluded = {};
  String? _previewError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadFiles);
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _previewError = null;
    });
    try {
      final result = await widget.loadFiles(_target, Set.of(_excluded));
      if (!mounted || request != _request) return;
      setState(() {
        _preview = result;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _previewError = '$error'.replaceFirst('FormatException: ', '');
        _loading = false;
      });
    }
  }

  bool get _ready =>
      !_loading &&
      _preview != null &&
      _preview!.writes.any((f) => !_excluded.contains(f.id)) &&
      _preview!.selectionIssues.isEmpty &&
      _previewError == null &&
      widget.packageReady &&
      !widget.baselineIntegrityBroken &&
      _exit &&
      _latest &&
      _modify;

  Widget _checks(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.description,
            style: RmText.sans(13, color: rm.fg2, height: 1.55),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _targetOption(
                  context,
                  GameDeploymentTarget.mediapc,
                  'mediapc（默认）',
                  '保留游戏原文件，使用覆盖资源',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _targetOption(
                  context,
                  GameDeploymentTarget.media,
                  'media（覆盖原文件）',
                  '覆盖游戏原文件，游戏更新可能恢复',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: rm.raised,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: Column(
              children: [
                StudioChecklistItem(
                  label: 'FH6 已退出（包括 Steam 后台 / 云同步队列）',
                  value: _exit,
                  onChanged: (v) => setState(() => _exit = v),
                ),
                StudioChecklistItem(
                  label: widget.latestConfirmation,
                  value: _latest,
                  onChanged: (v) => setState(() => _latest = v),
                ),
                StudioChecklistItem(
                  label: widget.modificationConfirmation,
                  value: _modify,
                  onChanged: (v) => setState(() => _modify = v),
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          StudioModalFacts(
            wrapValues: true,
            rows: [
              ('写入位置', p.join(widget.gameDir, _target.directoryName)),

              (
                '本次写入',
                _loading
                    ? '正在读取清单…'
                    : _preview == null
                    ? '清单读取失败'
                    : '已选 ${_preview!.selectedCount} / ${_preview!.writes.length} 个文件',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _files({required bool scrollable}) => DeploymentFileList(
    key: const ValueKey('deploy-files-panel'),
    preview: _preview,
    loading: _loading,
    error: _previewError,
    onReload: _loadFiles,
    excludedFiles: _excluded,
    onToggle: (id) {
      setState(() {
        if (!_excluded.add(id)) _excluded.remove(id);
      });
      _loadFiles();
    },
    onSelectAll: (all) {
      setState(() {
        _excluded.clear();
        if (!all) _excluded.addAll(_preview!.writes.map((f) => f.id));
      });
      _loadFiles();
    },
    scrollable: scrollable,
  );

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Dialog(
      key: const ValueKey('deploy-preview-dialog'),
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 1040,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StudioModalHead(
              title: widget.title,
              eyebrow: 'PRE-FLIGHT',
              overline: '写入前检查',
              icon: 'export',
            ),
            Flexible(
              child: LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 860
                    ? SizedBox(
                        height: 420,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 1,
                              child: SingleChildScrollView(
                                child: _checks(context),
                              ),
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: rm.border,
                            ),
                            Expanded(flex: 1, child: _files(scrollable: true)),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _checks(context),
                            Divider(height: 24, color: rm.border),
                            _files(scrollable: false),
                          ],
                        ),
                      ),
              ),
            ),
            StudioModalFoot(
              action: '确认写入',
              danger: false,
              enabled: _ready,
              icon: 'export',
              onConfirm: () => Navigator.of(
                context,
              ).pop(DeploymentChoice(_target, Set.unmodifiable(_excluded))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetOption(
    BuildContext context,
    GameDeploymentTarget target,
    String title,
    String subtitle,
  ) {
    final rm = context.rm;
    final selected = _target == target;
    return Semantics(
      key: ValueKey('deploy-choice-${target.directoryName}'),
      selected: selected,
      button: true,
      child: Material(
        color: selected ? rm.accent.bg : rm.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RmTokens.rMd),
          side: BorderSide(color: selected ? rm.accent.ring : rm.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('deploy-target-${target.directoryName}'),
          onTap: () {
            if (_target == target) return;
            setState(() {
              _target = target;
              _preview = null;
            });
            _loadFiles();
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                RmIcon(
                  selected ? 'check' : 'folder',
                  size: 16,
                  color: selected ? rm.accent.base : rm.fg3,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: RmText.sans(
                          12,
                          weight: FontWeight.w600,
                          color: selected ? rm.accent.base : rm.fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(subtitle, style: RmText.sans(11, color: rm.fg3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
