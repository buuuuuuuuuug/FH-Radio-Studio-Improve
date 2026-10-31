part of '../voice_replacement.dart';

extension _VoiceView on _VoiceReplacementState {
  void _escapeWorkspace() {
    if (_renamingFolder != null) {
      _update(() => _renamingFolder = null);
      return;
    }
    if (_playing != null) unawaited(_voicePlayer.stop());
    _update(() {
      _playing = null;
      _selectingExport = false;
      _exportEntries.clear();
      _entryAnchor = null;
      _selectingAssets = false;
      _selectedAssets.clear();
      _selectedAsset = null;
      _assetAnchor = null;
    });
  }

  Widget _view() {
    ref.watch(studioProvider);
    return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
                unawaited(_save()),
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
                _history(false),
            const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
                _history(true),
            const SingleActivator(LogicalKeyboardKey.space): () {
              if (_entry != null) unawaited(_play('original'));
            },
            const SingleActivator(LogicalKeyboardKey.escape): _escapeWorkspace,
          },
          child: Focus(
            focusNode: _workspaceFocus,
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape &&
                  (ModalRoute.of(context)?.isCurrent ?? true)) {
                _escapeWorkspace();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _pageHeader(),
                  const SizedBox(height: 9),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final workspaceWidth = math.max(466.0, c.maxWidth);
                        final centerMin = math.min(
                          320.0,
                          math.max(180.0, workspaceWidth - 286),
                        );
                        final available = math.max(
                          200.0,
                          workspaceWidth - centerMin - 16,
                        );
                        const minLeft = 125.0, minRight = 145.0;
                        final leftExtra = math.max(0.0, _leftWidth - minLeft);
                        final rightExtra = math.max(
                          0.0,
                          _rightWidth - minRight,
                        );
                        final factor = math.min(
                          1.0,
                          math.max(0.0, available - minLeft - minRight) /
                              math.max(.001, leftExtra + rightExtra),
                        );
                        final left = minLeft + leftExtra * factor,
                            right = minRight + rightExtra * factor;
                        final workspace = SizedBox(
                          width: workspaceWidth,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: left,
                                child: _library(),
                              ).tourAnchor('resources'),
                              _splitHandle(
                                'voice-left-divider',
                                left,
                                right,
                                workspaceWidth - right - centerMin - 16,
                                workspaceWidth - left - centerMin - 16,
                              ),
                              Expanded(child: _workbench()),
                              _splitHandle(
                                'voice-right-divider',
                                left,
                                right,
                                workspaceWidth - right - centerMin - 16,
                                workspaceWidth - left - centerMin - 16,
                              ),
                              SizedBox(
                                width: right,
                                child: _pool(),
                              ).tourAnchor('pool'),
                            ],
                          ),
                        );
                        return workspaceWidth > c.maxWidth
                            ? SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: workspace,
                              )
                            : workspace;
                      },
                    ),
                  ),
                  const SizedBox(height: 7),
                  _shortcutLegend(),
                ],
              ),
            ),
          ),
        )
        .withAudioImportProgress(count: _importCount, noun: '语音素材')
        .withFeatureTour(TourPage.voices, enabled: _session.loaded && !_busy);
  }

  Widget _pageHeader() {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('语音替换', style: RmText.pageH1(color: context.rm.fg)),
        const SizedBox(height: 6),
        SizedBox(
          height: 20,
          child: Row(
            children: [
              if (_busy) ...[
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: context.rm.accent.base,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: RmTooltip(
                  message:
                      _error ??
                      _notice ??
                      (_busy
                          ? (_busyText.isEmpty ? '正在处理…' : _busyText)
                          : _dirty
                          ? '草稿已缓存，保存修改后用于构建。'
                          : '备份与解析 → 对照试听与替换 → 单独构建并写入'),
                  child: Text(
                    _error ??
                        _notice ??
                        (_busy
                            ? (_busyText.isEmpty ? '正在处理…' : _busyText)
                            : _dirty
                            ? '草稿已缓存，保存修改后用于构建。'
                            : '备份与解析 → 对照试听与替换 → 单独构建并写入'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.sans(
                      12,
                      color: _error != null
                          ? context.rm.danger
                          : context.rm.fg3,
                    ),
                  ),
                ),
              ),
              if (!_busy && (_error != null || _notice != null))
                SizedBox(
                  width: 20,
                  height: 20,
                  child: RmButton(
                    leading: const RmIcon('x', size: 11),
                    size: RmButtonSize.sm,
                    horizontalPadding: 0,
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭提示',
                    onPressed: () => _update(() {
                      _error = null;
                      _notice = null;
                    }),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      key: const ValueKey('voice-workflow-actions'),
      spacing: 7,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        RmButton(
          key: const ValueKey('voice-save'),
          label: '保存修改',
          leading: const RmIcon('save', size: 12),
          onPressed: _locked || !_dirty ? null : () => unawaited(_save()),
        ),
        RmButton(
          key: const ValueKey('voice-build'),
          label: '构建准备包',
          leading: const RmIcon('music', size: 12),
          onPressed: _locked ? null : _build,
        ),
        RmButton(
          key: const ValueKey('voice-deploy'),
          label: '写入游戏',
          leading: const RmIcon('export', size: 12),
          variant: RmButtonVariant.primary,
          onPressed: _locked || !_packageReady || _dirty
              ? null
              : _deployVoicePackage,
        ),
      ],
    ).tourAnchor('workflow');
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 920
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: title),
                const SizedBox(width: 18),
                actions,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 10), actions],
            ),
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _shortcutLegend() => const EditorShortcutHints(
    hints: [
      'Ctrl + S 保存',
      'Ctrl + Z 撤销',
      'Ctrl + Y 重做',
      'Space 试听原音',
      'Ctrl 多选',
      'Shift 连选',
      'Esc 退出多选',
    ],
  );

  Widget _splitHandle(
    String id,
    double left,
    double right,
    double maxLeft,
    double maxRight,
  ) => RmTooltip(
    message: '拖动调整宽度；双击恢复默认',
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: ValueKey(id),
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (d) {
          _leftWidth = left;
          _rightWidth = right;
          _paneDrag = (
            origin: d.globalPosition.dx,
            left: left,
            right: right,
            maxLeft: maxLeft,
            maxRight: maxRight,
          );
        },
        onHorizontalDragUpdate: (d) {
          final drag = _paneDrag;
          if (drag == null) return;
          final delta = d.globalPosition.dx - drag.origin;
          _update(() {
            if (id == 'voice-left-divider') {
              _leftWidth = (drag.left + delta).clamp(
                125.0,
                math.max(125.0, drag.maxLeft),
              );
              _rightWidth = drag.right;
            } else {
              _rightWidth = (drag.right - delta).clamp(
                145.0,
                math.max(145.0, drag.maxRight),
              );
              _leftWidth = drag.left;
            }
          });
        },
        onHorizontalDragEnd: (_) {
          _paneDrag = null;
          unawaited(_rememberLayout());
        },
        onHorizontalDragCancel: () => _paneDrag = null,
        onDoubleTap: () {
          _update(() {
            _leftWidth = 190;
            _rightWidth = 220;
          });
          unawaited(_rememberLayout());
        },
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 2,
              height: 32,
              decoration: BoxDecoration(
                color: context.rm.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Widget _panel(
    String title,
    Widget body, {
    Widget? trailing,
    String? hint,
  }) => Container(
    decoration: BoxDecoration(
      color: context.rm.panel,
      border: Border.all(color: context.rm.border),
      borderRadius: BorderRadius.circular(RmTokens.rLg),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: SizedBox(
            height: 22,
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: RmTooltip(
                            message: hint ?? title,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.sans(
                                15,
                                color: context.rm.fg,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        if (hint != null && box.maxWidth > 440) ...[
                          const SizedBox(width: 14),
                          Expanded(
                            flex: 5,
                            child: RmTooltip(
                              message: hint,
                              child: Text(
                                hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: RmText.sans(11, color: context.rm.fg3),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * .42),
                      child: trailing,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Divider(height: 1, color: context.rm.border),
        Expanded(child: body),
      ],
    ),
  );
  Widget _confirmLine(String icon, String title, String detail) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RmIcon(icon, color: context.rm.accent.base, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: RmText.sans(
                  12,
                  color: context.rm.fg,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: RmText.sans(11.5, color: context.rm.fg3, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _size(Object? bytes) {
    final n = stingerNumber(bytes);
    if (n >= 1073741824) return '${(n / 1073741824).toStringAsFixed(2)} GiB';
    if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MiB';
    return '${(n / 1024).toStringAsFixed(1)} KiB';
  }
}

class _VoiceCheck extends StatelessWidget {
  const _VoiceCheck({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool?>? onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    height: 24,
    child: Transform.scale(
      scale: .8,
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
        side: WidgetStateBorderSide.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? context.rm.accent.base
                : context.rm.borderStrong,
            width: 1,
          ),
        ),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? context.rm.accent.base
              : context.rm.panel,
        ),
        checkColor: context.rm.accent.onAccent,
      ),
    ),
  );
}
