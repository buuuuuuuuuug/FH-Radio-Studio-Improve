import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/radio_library.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'assignment_radio_choice.dart';
import 'assignment_shortcuts.dart';
import 'rm_button.dart';

class BatchAssignmentInfo {
  const BatchAssignmentInfo({
    required this.total,
    required this.added,
    required this.limit,
    required this.replacesBuiltin,
    this.crossRadioCount = 0,
  });
  final int total, added, limit;
  final bool replacesBuiltin;
  final int crossRadioCount;
}

class BatchAssignmentDialog extends StatefulWidget {
  const BatchAssignmentDialog({
    super.key,
    required this.radios,
    required this.tracks,
    required this.splitTypes,
    required this.initialType,
    required this.info,
  });
  final List<RadioStation> radios;
  final List<PoolTrack> tracks;
  final bool splitTypes;
  final String initialType;
  final BatchAssignmentInfo Function(RadioStation, String) info;
  @override
  State<BatchAssignmentDialog> createState() => _BatchAssignmentDialogState();
}

class _BatchAssignmentDialogState extends State<BatchAssignmentDialog> {
  late String _radio = widget.radios.first.code;
  late String _type = widget.initialType;
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void confirm() {
    final radio = widget.radios.firstWhere((r) => r.code == _radio);
    final info = widget.info(radio, _type);
    if (info.total > info.limit || info.added == 0) return;
    Navigator.pop(context, (radio: _radio, type: _type, limit: info.limit));
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final info = widget.info(
      widget.radios.firstWhere((r) => r.code == _radio),
      _type,
    );
    final exceeds = info.total > info.limit;
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (!assignmentKeyboardAvailable(context, e)) {
          return KeyEventResult.ignored;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape &&
            !HardwareKeyboard.instance.isControlPressed) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.enter &&
            !HardwareKeyboard.instance.isControlPressed) {
          confirm();
          return KeyEventResult.handled;
        }
        final shortcut = assignmentDigitShortcut(
          e,
          splitTypes: widget.splitTypes,
        );
        final matches = widget.radios.where((r) => r.code == shortcut?.radio);
        if (shortcut != null && matches.isNotEmpty) {
          setState(() {
            _radio = matches.first.code;
            _type = shortcut.type;
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        key: const ValueKey('batch-assignment-dialog'),
        backgroundColor: rm.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          side: BorderSide(color: rm.border),
        ),
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: rm.accent.bg,
                        borderRadius: BorderRadius.circular(RmTokens.rSm),
                      ),
                      child: Icon(
                        Icons.radio_outlined,
                        color: rm.accent.base,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (info.crossRadioCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                '${info.crossRadioCount} 首歌曲也分配在其他电台；原分配会保留，每个电台分别收录，增加准备包体积。',
                                style: RmText.sans(12, color: rm.warn),
                              ),
                            ),
                          Text(
                            '分配 ${widget.tracks.length} 首歌曲',
                            style: RmText.modalH2(color: rm.fg),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            assignmentShortcutHint(
                              splitTypes: widget.splitTypes,
                              batch: true,
                            ),
                            style: RmText.sans(11, color: rm.fg3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: rm.border),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: rm.raised,
                            borderRadius: BorderRadius.circular(RmTokens.rSm),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final t in widget.tracks.take(2))
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    '${t.title} · ${t.artist}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: RmText.sans(11.5, color: rm.fg2),
                                  ),
                                ),
                              if (widget.tracks.length > 2)
                                Text(
                                  '另有 ${widget.tracks.length - 2} 首',
                                  style: RmText.sans(11, color: rm.fg3),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (widget.splitTypes) ...[
                          Row(
                            children: [
                              Text(
                                '场景',
                                style: RmText.sans(11.5, color: rm.fg3),
                              ),
                              const SizedBox(width: 12),
                              for (final type in ['FreeRoam', 'Event'])
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: RmButton(
                                    key: ValueKey('batch-type-$type'),
                                    label: type == 'Event' ? '比赛' : '漫游',
                                    size: RmButtonSize.sm,
                                    variant: _type == type
                                        ? RmButtonVariant.primary
                                        : RmButtonVariant.defaultBtn,
                                    onPressed: () =>
                                        setState(() => _type = type),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        for (final r in widget.radios) ...[
                          Builder(
                            builder: (context) {
                              final preview = widget.info(r, _type);
                              return AssignmentRadioChoice(
                                choiceKey: ValueKey('batch-assign-${r.code}'),
                                radio: r,
                                selected: r.code == _radio,
                                summary:
                                    '${preview.total} / ${preview.limit == 4096 ? '扩容' : preview.limit}${preview.total > preview.limit ? ' · 超额' : ''}',
                                summaryColor: preview.total > preview.limit
                                    ? rm.danger
                                    : null,
                                onTap: () => setState(() => _radio = r.code),
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Container(height: 1, color: rm.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      key: const ValueKey('batch-assign-status'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: exceeds ? rm.dangerBg : rm.raised,
                        borderRadius: BorderRadius.circular(RmTokens.rSm),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            exceeds
                                ? Icons.warning_amber_rounded
                                : Icons.info_outline,
                            size: 16,
                            color: exceeds ? rm.danger : rm.fg2,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${widget.splitTypes ? '目标 $_radio · ${_type == 'Event' ? '比赛' : '漫游'}\n' : ''}新增 ${info.added} 首 · 分配后 ${info.total} / ${info.limit == 4096 ? '扩容' : info.limit} 首\n${exceeds
                                  ? '超过电台容量，请减少选择或更换电台；本次不会部分分配。'
                                  : info.added == 0
                                  ? '这些歌曲已在目标电台，无需重复分配。'
                                  : info.replacesBuiltin
                                  ? '该电台将由原版切换为自建曲目。'
                                  : '按列表顺序追加；目标已有歌曲不重复添加。'}',
                              style: RmText.sans(
                                11.5,
                                color: exceeds ? rm.danger : rm.fg2,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        RmButton(
                          label: '取消',
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 8),
                        RmButton(
                          key: const ValueKey('batch-assign-confirm'),
                          label: info.replacesBuiltin ? '切换并分配' : '分配',
                          variant: RmButtonVariant.primary,
                          onPressed: exceeds || info.added == 0
                              ? null
                              : confirm,
                        ),
                      ],
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
