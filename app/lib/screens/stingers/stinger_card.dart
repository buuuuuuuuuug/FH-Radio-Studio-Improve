import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../widgets/rm_icon.dart';
import '../playlist/track_card.dart';

/// Audio actions around the shared playlist card, with no separate card styling.
class StingerCard extends StatelessWidget {
  const StingerCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.duration,
    this.order,
    this.numberOnly = false,
    this.accent = false,
    this.dragging = false,
    this.selected = false,
    this.selectionMode = false,
    this.playing = false,
    this.onPlay,
    this.onEdit,
    this.onAssign,
    this.onRemove,
    this.onSelect,
    this.dragBuilder,
    this.onActivate,
    this.pending = false,
  });
  final String title, subtitle;
  final double? duration;
  final int? order;
  final bool numberOnly;
  final bool accent, dragging, selected, selectionMode, playing;
  final VoidCallback? onPlay, onEdit, onAssign, onRemove;
  final void Function(bool control, bool shift)? onSelect;
  final Widget Function(Widget body)? dragBuilder;
  final VoidCallback? onActivate;
  final bool pending;

  @override
  Widget build(BuildContext context) => TrackCard(
    title: title,
    artist: subtitle,
    durationSec: duration ?? 0,
    showDuration: duration != null,
    pending: pending,
    locked: !accent && !pending,
    custom: accent,
    dragging: dragging,
    order: order,
    numberOnly: numberOnly,
    selected: selected,
    selectionMode: selectionMode,
    onSelect: onSelect,
    onActivate: onActivate,
    onOpenEditor: onEdit,
    allowLockedOpen: true,
    tooltip: onEdit == null
        ? '点击播放按钮试听；再次点击停止'
        : onAssign != null
        ? '双击编辑 · Ctrl + D 分配 · Ctrl 多选 · Shift 连选'
        : '双击编辑 · 拖入分配 · Ctrl 多选 · Shift 连选',
    bodyBuilder: dragBuilder,
    trailing: pending || dragging && onPlay == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 27,
                child: IconButton(
                  key: ValueKey('play-$title-$order'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: playing ? '停止试听' : '试听',
                  onPressed: onPlay,
                  icon: RmIcon(
                    playing ? 'stop' : 'play',
                    size: 13,
                    color: onPlay == null
                        ? context.rm.fg4
                        : playing
                        ? context.rm.accent.base
                        : context.rm.fg2,
                  ),
                ),
              ),
              if (onRemove != null && onAssign != null) ...[
                const SizedBox(width: 3),
                SizedBox(
                  width: 22,
                  height: 27,
                  child: IconButton(
                    key: ValueKey('remove-$title-$order'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: '移除素材',
                    onPressed: onRemove,
                    icon: RmIcon('trash', size: 13, color: context.rm.danger),
                  ),
                ),
              ],
            ],
          ),
  );
}
