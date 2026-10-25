import 'playlist_draggable.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_icon.dart';

/// playlist 列里一行 track。
/// - `locked = true` → 原版曲目，半透明且不可拖
/// - `locked = false` → 自建曲目，accent 高亮且可拖
///
/// 拖拽部分由父 widget（`Draggable`）外包；本 widget 只关心视觉。
class TrackCard extends StatefulWidget {
  const TrackCard({
    super.key,
    required this.title,
    required this.artist,
    required this.durationSec,
    required this.locked,
    this.custom = false,
    this.notConfiguredProgress, // e.g. "2/4" — null 表示已配置
    this.siren = false,
    this.assignmentLabels = const [],
    this.dragging = false,
    this.order,
    this.onOpenEditor,
    this.onSelect,
    this.selected = false,
    this.selectionMode = false,
  });

  final String title;
  final String artist;
  final double durationSec;
  final bool locked;
  final bool custom;
  final String? notConfiguredProgress;
  final bool siren;
  final List<String> assignmentLabels;
  final bool dragging;
  final int? order;
  final VoidCallback? onOpenEditor;
  final void Function(bool control, bool shift)? onSelect;
  final bool selected;
  final bool selectionMode;

  /// 工厂：从 PoolTrack 创建（自建曲目）。
  factory TrackCard.fromPoolTrack(
    PoolTrack t, {
    bool dragging = false,
    int? order,
    bool locked = false,
    List<String> assignmentLabels = const [],
    VoidCallback? onOpenEditor,
    void Function(bool control, bool shift)? onSelect,
    bool selected = false,
    bool selectionMode = false,
  }) {
    return TrackCard(
      title: t.title,
      artist: t.artist,
      durationSec: t.durationSec,
      locked: locked,
      custom: true,
      notConfiguredProgress: t.readyForBuild ? null : '${t.confirmed}/4',
      siren: t.isSiren,
      assignmentLabels: assignmentLabels,
      dragging: dragging,
      order: order,
      onOpenEditor: onOpenEditor,
      onSelect: onSelect,
      selected: selected,
      selectionMode: selectionMode,
    );
  }

  @override
  State<TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<TrackCard> {
  bool _hover = false;
  bool _controlAtDown = false;
  bool _shiftAtDown = false;
  Offset? _selectionDown;
  void _captureModifiers(PointerDownEvent event) {
    _controlAtDown = HardwareKeyboard.instance.isControlPressed;
    _shiftAtDown = HardwareKeyboard.instance.isShiftPressed;
    _selectionDown = event.buttons == 1 ? event.position : null;
  }

  void _selectOnRelease(PointerUpEvent event) {
    final down = _selectionDown;
    _selectionDown = null;
    if (down != null &&
        (event.position - down).distance < playlistDragDistance &&
        (widget.selectionMode || _controlAtDown || _shiftAtDown)) {
      _select();
    }
  }

  void _select() => widget.onSelect?.call(_controlAtDown, _shiftAtDown);

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final locked = widget.locked;
    final modded = widget.custom || !locked;
    final canEdit = !locked && widget.onOpenEditor != null;
    final badges = _badges(rm);

    final Color bg;
    final Color border;
    if (widget.dragging) {
      bg = rm.accent.bg;
      border = rm.accent.base;
    } else if (widget.selected) {
      bg = rm.accent.bg;
      border = rm.accent.base;
    } else if (widget.custom && widget.notConfiguredProgress != null) {
      bg = rm.warnBg;
      border = rm.warn.withAlpha(165);
    } else if (modded) {
      bg = rm.accent.bg;
      border = rm.accent.ring;
    } else if (_hover) {
      bg = rm.raised;
      border = rm.border;
    } else {
      bg = Colors.transparent;
      border = Colors.transparent;
    }

    return Listener(
      onPointerDown: _captureModifiers,
      onPointerUp: _selectOnRelease,
      onPointerMove: (event) {
        if (_selectionDown != null &&
            (event.position - _selectionDown!).distance >=
                playlistDragDistance) {
          _selectionDown = null;
        }
      },
      onPointerCancel: (_) => _selectionDown = null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.selectionMode || !canEdit
            ? null
            : () {
                if (!_controlAtDown && !_shiftAtDown) widget.onOpenEditor!();
              },
        child: Tooltip(
          message: locked
              ? ''
              : widget.onOpenEditor == null
              ? (widget.custom ? '曲目当前不可编辑' : '原版曲目没有本地编辑配置')
              : (widget.onSelect == null
                    ? '双击进入编辑；拖动可调整排序'
                    : '双击编辑 · Ctrl 多选 · Shift 连选'),
          waitDuration: const Duration(milliseconds: 450),
          child: MouseRegion(
            cursor: locked ? SystemMouseCursors.basic : SystemMouseCursors.grab,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Opacity(
              opacity: locked ? 0.8 : 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                decoration: BoxDecoration(
                  color: bg,
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(RmTokens.rSm),
                ),
                child: Row(
                  children: [
                    if (widget.selectionMode) ...[
                      SizedBox(
                        width: 18,
                        height: 26,
                        child: Icon(
                          widget.selected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 15,
                          color: widget.selected ? rm.accent.base : rm.fg4,
                        ),
                      ),
                      const SizedBox(width: 5),
                    ] else if (widget.order != null) ...[
                      SizedBox(
                        width: 18,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RmIcon(
                              locked ? 'lock' : 'drag',
                              size: 9,
                              color: rm.fg4,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.order.toString().padLeft(2, '0'),
                              style: RmText.mono(9, color: rm.fg3),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 5),
                    ] else ...[
                      RmIcon(
                        locked ? 'lock' : 'drag',
                        size: locked ? 10 : 12,
                        color: rm.fg4,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.title,
                                  style: RmText.sans(
                                    12.5,
                                    weight: FontWeight.w500,
                                    color:
                                        widget.custom &&
                                            widget.notConfiguredProgress != null
                                        ? rm.warn
                                        : modded
                                        ? rm.accent.base
                                        : (locked ? rm.fg2 : rm.fg),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.artist,
                            style: RmText.sans(
                              11,
                              color: locked ? rm.fg4 : rm.fg3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (badges.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Wrap(spacing: 4, runSpacing: 3, children: badges),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _short(widget.durationSec),
                      style: RmText.mono(10.5, color: rm.fg3),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _short(double t) {
    final m = t ~/ 60;
    final s = (t % 60).floor();
    return '$m:${s.toString().padLeft(2, "0")}';
  }

  List<Widget> _badges(RmTheme rm) {
    return [
      if (widget.siren)
        _TrackBadge(
          label: 'MSR',
          text: rm.accent.base,
          border: rm.accent.ring,
          bg: Color.alphaBlend(rm.accent.base.withAlpha(18), rm.raised),
          dot: rm.accent.base,
        ),
      if (widget.notConfiguredProgress != null)
        _TrackBadge(
          label: '未完成 ${widget.notConfiguredProgress!}',
          text: rm.warn,
          border: rm.warn.withAlpha(102),
          bg: rm.warnBg,
          dot: rm.warn,
        ),
      if (widget.assignmentLabels.isNotEmpty)
        Tooltip(
          message: widget.assignmentLabels.join('\n'),
          waitDuration: const Duration(milliseconds: 350),
          child: _TrackBadge(
            label: widget.assignmentLabels.length == 1
                ? widget.assignmentLabels.first
                : '${widget.assignmentLabels.length} 个列表',
            text: rm.fg2,
            border: rm.border,
            bg: rm.raised,
            dot: rm.fg3,
          ),
        ),
    ];
  }
}

class _TrackBadge extends StatelessWidget {
  const _TrackBadge({
    required this.label,
    required this.text,
    required this.border,
    required this.bg,
    required this.dot,
  });

  final String label;
  final Color text;
  final Color border;
  final Color bg;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.mono(10, color: text),
            ),
          ),
        ],
      ),
    );
  }
}
