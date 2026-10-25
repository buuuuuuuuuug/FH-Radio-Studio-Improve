import 'assignment_radio_choice.dart';
import 'assignment_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/playlist_plan.dart';
import '../domain/radio_library.dart';
import '../screens/playlist/playlist_state.dart';
import '../state/editor_options.dart';
import '../state/playlist_catalog_state.dart';
import '../state/playlist_plan_state.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';
import '../theme/tokens.dart';

PlaylistPlan editableAssignmentPlan(WidgetRef ref) {
  final plan = ref.read(effectivePlaylistPlanProvider);
  if (plan.hasDraft || ref.read(playlistPlanProvider.notifier).hasUserPlan) {
    return plan;
  }
  final catalog = ref.read(playlistCatalogProvider);
  return catalog.failed
      ? plan
      : playlistPlanFromCatalog(
          catalog,
          ref.read(playlistProvider).pool,
          projectDir: ref.read(studioProvider).projectDir,
          includeBuiltinTargets: false,
        );
}

int assignmentLimit(WidgetRef ref, RadioStation radio, String type) {
  if (ref.read(editorOptionsProvider).expansionEnabled) return 4096;
  final original =
      ref
          .read(baselinePlaylistCatalogProvider)
          ?.tracksOfRadio(radio.code, type)
          .length ??
      0;
  return original > 0 ? original : radio.slot;
}

Future<bool> showQuickAssign(BuildContext context, PoolTrack track) async =>
    await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (_) => QuickAssignDialog(track: track),
    ) ??
    false;

class QuickAssignDialog extends ConsumerStatefulWidget {
  const QuickAssignDialog({super.key, required this.track});
  final PoolTrack track;
  @override
  ConsumerState<QuickAssignDialog> createState() => _QuickAssignDialogState();
}

class _QuickAssignDialogState extends ConsumerState<QuickAssignDialog> {
  final focus = FocusNode();
  late final project = ref.read(studioProvider).projectDir;
  String? error;
  String selectedType = 'Event';
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void assign(RadioStation radio, String type) {
    if (ref.read(studioProvider).projectDir != project ||
        ref.read(studioProvider).projectEditingLocked) {
      setState(() => error = '项目状态已变化，请关闭后重试。');
      return;
    }
    final controller = ref.read(playlistProvider.notifier);
    final ok = controller.assignManyToRadio(
      [widget.track.id],
      radio.code,
      type,
      maxSlots: assignmentLimit(ref, radio, type),
    );
    if (!ok) {
      setState(
        () => error =
            controller.lastEditBlockedReason ??
            '${radio.code} 已满或歌曲状态已变化，请选择其他电台。',
      );
      return;
    }
    final radios =
        editableAssignmentPlan(ref)
            .assignmentsForPath(widget.track.source)
            .map((a) => a.radioCode)
            .toSet()
            .toList()
          ..sort();
    final suffix = radios.length > 1
        ? '现已分配到 ${radios.join(' / ')}，原分配保留；每个电台会分别收录。'
        : '可在播放列表保存或撤销。';
    final scene = ref.read(playlistProvider).splitPlaylistTypes
        ? ' · ${PlaylistAssignment.playlistLabel(type)}'
        : '';
    Navigator.pop(context, true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已分配到 ${radio.code}$scene；$suffix')));
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final catalog = ref.watch(playlistCatalogProvider);
    ref.watch(effectivePlaylistPlanProvider);
    final state = ref.watch(playlistProvider);
    final type = state.splitPlaylistTypes ? selectedType : 'FreeRoam';
    final plan = editableAssignmentPlan(ref);
    final currentAssignments = plan.assignmentsForPath(widget.track.source);
    final currentLabels =
        currentAssignments
            .map(
              (a) => state.splitPlaylistTypes
                  ? '${a.radioCode} · ${PlaylistAssignment.playlistLabel(a.playlistType)}'
                  : a.radioCode,
            )
            .toSet()
            .toList()
          ..sort();
    final radios =
        catalog.radios
            .where(
              (r) =>
                  RegExp(r'^R[1-9]$').hasMatch(r.code) &&
                  isUiSupportedRadio(name: r.name),
            )
            .toList()
          ..sort((a, b) => a.code.compareTo(b.code));
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (!assignmentKeyboardAvailable(context, e)) {
          return KeyEventResult.ignored;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape &&
            !HardwareKeyboard.instance.isControlPressed) {
          Navigator.pop(context, false);
          return KeyEventResult.handled;
        }
        final shortcut = assignmentDigitShortcut(
          e,
          splitTypes: state.splitPlaylistTypes,
        );
        final matches = radios.where((r) => r.code == shortcut?.radio);
        if (shortcut != null && matches.isNotEmpty) {
          assign(matches.first, shortcut.type);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: rm.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          side: BorderSide(color: rm.border),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                          Text('分配至电台', style: RmText.modalH2(color: rm.fg)),
                          const SizedBox(height: 3),
                          Text(
                            assignmentShortcutHint(
                              splitTypes: state.splitPlaylistTypes,
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
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          widget.track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: RmText.sans(
                            14,
                            weight: FontWeight.w600,
                            color: rm.fg,
                          ),
                        ),
                        if (widget.track.artist.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            widget.track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(11.5, color: rm.fg3),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (state.splitPlaylistTypes) ...[
                          Row(
                            children: [
                              Text(
                                '场景',
                                style: RmText.sans(11.5, color: rm.fg3),
                              ),
                              const SizedBox(width: 12),
                              for (final scene in const ['Event', 'FreeRoam'])
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: RmButton(
                                    key: ValueKey('quick-type-$scene'),
                                    label: scene == 'Event' ? '比赛' : '漫游',
                                    size: RmButtonSize.sm,
                                    variant: selectedType == scene
                                        ? RmButtonVariant.primary
                                        : RmButtonVariant.defaultBtn,
                                    onPressed: () => setState(() {
                                      selectedType = scene;
                                      error = null;
                                    }),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (plan
                            .assignmentsForPath(widget.track.source)
                            .isNotEmpty) ...[
                          Text(
                            '当前分配：${currentLabels.join(' / ')}',
                            style: RmText.sans(12, color: rm.warn),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '选择其他电台会保留原分配，每个电台分别收录，增加准备包体积。',
                            style: RmText.sans(11.5, color: rm.fg3),
                          ),
                          const SizedBox(height: 12),
                        ],
                        for (final radio in radios) ...[
                          _radioChoice(context, radio, type, plan),
                          const SizedBox(height: 6),
                        ],
                        if (catalog.failed)
                          Text(
                            '电台信息不可用，请先在概览刷新项目。',
                            style: RmText.sans(12, color: rm.warn),
                          ),
                        if (!(state.pool
                                    .where((t) => t.id == widget.track.id)
                                    .firstOrNull ??
                                widget.track)
                            .configured)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              state.splitPlaylistTypes
                                  ? '漫游无需人工确认时间点；用于比赛时需完成并保存。'
                                  : '可先分配；比赛需完成时间点并保存后才能构建。',
                              style: RmText.sans(11, color: rm.warn),
                            ),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              error!,
                              style: RmText.sans(12, color: rm.danger),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(height: 1, color: rm.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '分配到草稿，重复曲目不追加。\n${state.splitPlaylistTypes ? '首次分配会将当前场景切换为自建。' : '首次分配会将电台切换为自建。'}',
                        style: RmText.sans(10.5, color: rm.fg3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    RmButton(
                      label: '取消',
                      onPressed: () => Navigator.pop(context, false),
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

  Widget _radioChoice(
    BuildContext context,
    RadioStation radio,
    String type,
    PlaylistPlan plan,
  ) {
    final rm = context.rm;
    final count = plan.assignmentsForRadio(radio.code, type).length;
    final limit = assignmentLimit(ref, radio, type);
    final assigned =
        plan.assignmentFor(
          source: widget.track.source,
          radioCode: radio.code,
          playlistType: type,
        ) !=
        null;
    final full = count >= limit && !assigned;
    final color = assigned
        ? rm.accent.base
        : full
        ? rm.warn
        : rm.fg2;
    final scene = ref.read(playlistProvider).splitPlaylistTypes
        ? '${PlaylistAssignment.playlistLabel(type)} · '
        : '';
    final summary = assigned
        ? '已分配 · $count 首'
        : limit == 4096
        ? '$count 首 · 扩容'
        : '$count / $limit${full ? ' · 已满' : ''}';
    return AssignmentRadioChoice(
      choiceKey: ValueKey('quick-assign-${radio.code}'),
      radio: radio,
      selected: assigned,
      summary: '$scene$summary',
      summaryColor: color,
      onTap: () => assign(radio, type),
    );
  }
}
