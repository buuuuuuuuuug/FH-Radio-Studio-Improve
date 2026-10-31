import 'package:flutter/material.dart';
import '../../widgets/contained_scroll.dart';
import '../../widgets/smooth_scroll_to_top.dart';

import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';

/// playlist 看板的一列 — 支持三种 mode：
/// - customRadio: 接受拖入 + 显示 pool 中分配的歌
/// - builtinRadio: 半透明斜条纹背景 + 拖入弹切换警告
/// - pool: 虚线边 + 接受 unassign
enum ColumnKind { customRadio, builtinRadio, pool }

/// 列容器。拖拽接受与悬停高亮（`DragTarget` + overlay）由外层主屏处理；
/// 本 widget 只负责列的静态外观。
class PlaylistColumn extends StatefulWidget {
  const PlaylistColumn({
    super.key,
    required this.kind,
    required this.header,
    required this.children,
    this.emptyText,
    this.filterControls,
    this.metadata,
    this.fitContents = false,
    this.metadataPadding = const EdgeInsets.fromLTRB(8, 4, 8, 6),
  }) : itemCount = children.length,
       itemBuilder = null;

  const PlaylistColumn.builder({
    super.key,
    required this.kind,
    required this.header,
    required this.itemCount,
    required this.itemBuilder,
    this.emptyText,
    this.filterControls,
    this.metadata,
    this.fitContents = false,
    this.metadataPadding = const EdgeInsets.fromLTRB(8, 4, 8, 6),
  }) : children = const [];

  /// 普通电台列 (custom or builtin)
  factory PlaylistColumn.radio({
    required RadioStation radio,
    required bool isCustom,
    required int count,
    int? capacity,
    int pendingCount = 0,
    bool expanded = false,
    int? originalCount,
    required List<Widget> children,
    VoidCallback? onRestoreBuiltin,
    String? headerActionLabel,
    String? headerActionTooltip,
    VoidCallback? onHeaderAction,
  }) {
    return PlaylistColumn(
      kind: isCustom ? ColumnKind.customRadio : ColumnKind.builtinRadio,
      header: RadioColumnHeader(
        radio: radio,
        isCustom: isCustom,
        count: count,
        pendingCount: pendingCount,
        expanded: expanded,
        capacity: capacity ?? radio.slot,
        originalCount: originalCount ?? radio.slot,
        onRestoreBuiltin: onRestoreBuiltin,
        headerActionLabel: headerActionLabel,
        headerActionTooltip: headerActionTooltip,
        onHeaderAction: onHeaderAction,
      ),
      emptyText: isCustom ? '空 · 拖入池中曲目' : '无原版数据',
      children: children,
    );
  }

  factory PlaylistColumn.radioBuilder({
    required RadioStation radio,
    required bool isCustom,
    required int count,
    int? capacity,
    int pendingCount = 0,
    bool expanded = false,
    int? originalCount,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    VoidCallback? onRestoreBuiltin,
    String? headerActionLabel,
    String? headerActionTooltip,
    VoidCallback? onHeaderAction,
    Widget? filterControls,
  }) => PlaylistColumn.builder(
    kind: isCustom ? ColumnKind.customRadio : ColumnKind.builtinRadio,
    header: RadioColumnHeader(
      radio: radio,
      isCustom: isCustom,
      count: count,
      pendingCount: pendingCount,
      expanded: expanded,
      capacity: capacity ?? radio.slot,
      originalCount: originalCount ?? radio.slot,
      onRestoreBuiltin: onRestoreBuiltin,
      headerActionLabel: headerActionLabel,
      headerActionTooltip: headerActionTooltip,
      onHeaderAction: onHeaderAction,
    ),
    filterControls: filterControls,
    itemCount: itemCount,
    itemBuilder: itemBuilder,
    emptyText: isCustom ? '空 · 拖入池中曲目' : '无原版数据',
  );

  factory PlaylistColumn.poolBuilder({
    required int count,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    Widget? filterControls,
  }) {
    return PlaylistColumn.builder(
      kind: ColumnKind.pool,
      header: PlaylistPoolHeader(count: count),
      emptyText: '没有导入歌曲',
      itemCount: itemCount,
      itemBuilder: itemBuilder,
      filterControls: filterControls,
    );
  }

  final bool fitContents;
  final ColumnKind kind;
  final Widget header;
  final List<Widget> children;
  final int itemCount;
  final IndexedWidgetBuilder? itemBuilder;
  final String? emptyText;
  final Widget? filterControls;
  final Widget? metadata;
  final EdgeInsets metadataPadding;

  @override
  State<PlaylistColumn> createState() => _PlaylistColumnState();
}

class _PlaylistColumnState extends State<PlaylistColumn> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final builtin = widget.kind == ColumnKind.builtinRadio;
    final pool = widget.kind == ColumnKind.pool;

    final Color bg = pool ? rm.raised : rm.panel;
    final pending =
        widget.header is RadioColumnHeader &&
        (widget.header as RadioColumnHeader).pendingCount > 0;
    final Color borderColor = pool
        ? Colors.transparent
        : pending
        ? rm.warn.withAlpha(150)
        : rm.border;

    final borderRadius = BorderRadius.circular(RmTokens.rLg);
    final content = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor),
      ),
      child: Stack(
        children: [
          if (builtin)
            Positioned.fill(
              child: CustomPaint(
                painter: _DiagonalStripePainter(
                  color: rm.border.withAlpha(150),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: pool ? 7 : 12,
                ),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: widget.header,
              ),
              Container(
                padding: widget.metadataPadding,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: _meta(context),
              ),
              if (widget.filterControls != null) widget.filterControls!,
              if (widget.fitContents)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.itemCount; i++) ...[
                        if (i > 0) const SizedBox(height: 4),
                        widget.itemBuilder?.call(context, i) ??
                            widget.children[i],
                      ],
                    ],
                  ),
                )
              else
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: SmoothScrollToTop(
                      controller: _scroll,
                      enabled: pool,
                      compact: true,
                      bottom: 18,
                      child: ContainedScroll(
                        controller: _scroll,
                        child: widget.itemCount == 0
                            ? _empty(context)
                            : ListView.separated(
                                primary: false,
                                controller: _scroll,
                                physics: const ClampingScrollPhysics(),
                                itemCount: widget.itemCount,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 4),
                                itemBuilder: (context, i) {
                                  final itemBuilder = widget.itemBuilder;
                                  if (itemBuilder != null) {
                                    return itemBuilder(context, i);
                                  }
                                  return widget.children[i];
                                },
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    if (!pool) return content;
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        color: rm.borderStrong,
        radius: RmTokens.rLg,
      ),
      child: content,
    );
  }

  Widget _meta(BuildContext context) {
    final rm = context.rm;
    if (widget.metadata != null) return widget.metadata!;
    if (widget.header is RadioColumnHeader) {
      final header = widget.header as RadioColumnHeader;
      final count = header.expanded || header.capacity == 4096
          ? '${header.count} 首 · 原有 ${header.originalCount} 首 · 扩容'
          : '${header.count} / ${header.capacity}';
      return Wrap(
        spacing: 8,
        runSpacing: 2,
        children: [
          Text(count, style: RmText.mono(10.5, color: rm.fg3)),
          if (header.pendingCount > 0)
            Tooltip(
              message: '此电台有未完成或未确认的歌曲，完成并保存后才能构建。双击歌曲可编辑。',
              child: Text(
                '⚠ ${header.pendingCount} 首未完成',
                style: RmText.sans(
                  10.5,
                  weight: FontWeight.w600,
                  color: rm.warn,
                ),
              ),
            ),
        ],
      );
    }
    return Text(
      '${(widget.header as PlaylistPoolHeader).count} 首',
      style: RmText.mono(10.5, color: rm.fg3),
    );
  }

  Widget _empty(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
      child: Center(
        child: Text(
          widget.emptyText ?? '',
          style: RmText.mono(11.5, color: rm.fg4),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class RadioColumnHeader extends StatelessWidget {
  const RadioColumnHeader({
    super.key,
    required this.radio,
    required this.isCustom,
    required this.count,
    required this.capacity,
    this.pendingCount = 0,
    this.expanded = false,
    required this.originalCount,
    this.onRestoreBuiltin,
    this.headerActionLabel,
    this.headerActionTooltip,
    this.onHeaderAction,
    this.restoreTooltip = '恢复当前列表为 builtin',
  });

  final String restoreTooltip;
  final RadioStation radio;
  final bool isCustom;
  final int count;
  final int capacity;
  final int pendingCount;
  final bool expanded;
  final int originalCount;
  final VoidCallback? onRestoreBuiltin;
  final String? headerActionLabel;
  final String? headerActionTooltip;
  final VoidCallback? onHeaderAction;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: rm.raised,
                border: Border.all(color: rm.border),
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.center,
              child: Text(
                radio.code,
                style: RmText.mono(
                  10,
                  weight: FontWeight.w700,
                  color: _swatchColor(rm, radio.hue),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    radio.name,
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w600,
                      color: rm.fg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    radio.genre,
                    style: RmText.mono(10.5, color: rm.fg3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            isCustom
                ? const RmChip(
                    label: 'custom',
                    variant: RmChipVariant.accent,
                    showDot: true,
                  )
                : const RmChip(
                    label: 'builtin',
                    variant: RmChipVariant.muted,
                    leading: RmIcon('lock', size: 9),
                  ),
            if (headerActionLabel != null) ...[
              const SizedBox(width: 4),
              RmButton.icon(
                onPressed: onHeaderAction,
                icon: const Icon(Icons.swap_horiz, size: 14),
                variant: RmButtonVariant.ghost,
                tooltip: headerActionLabel,
              ),
            ] else if (headerActionLabel == null &&
                isCustom &&
                onRestoreBuiltin != null) ...[
              const SizedBox(width: 4),
              RmButton.icon(
                onPressed: onRestoreBuiltin,
                icon: const RmIcon('undo', size: 12),
                variant: RmButtonVariant.ghost,
                tooltip: restoreTooltip,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Color _swatchColor(RmTheme rm, String hue) {
    switch (hue) {
      case 'lime':
        return const Color(0xFF23A136);
      case 'cyan':
        return const Color(0xFF008DA4);
      case 'orange':
        return const Color(0xFFD75C00);
      case 'magenta':
        return const Color(0xFFBD2099);
      case 'red':
        return rm.danger;
      case 'violet':
        return const Color(0xFF6F4DBF);
      case 'yellow':
        return const Color(0xFFA68000);
      case 'teal':
        return const Color(0xFF008B83);
    }
    return rm.fg;
  }
}

class PlaylistPoolHeader extends StatelessWidget {
  const PlaylistPoolHeader({
    super.key,
    required this.count,
    this.title = '池子',
    this.subtitle = '全部曲目 · 配置完善靠前',
  });
  final int count;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: rm.raised,
                border: Border.all(color: rm.border),
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.center,
              child: RmIcon('music', size: 12, color: rm.fg2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w600,
                      color: rm.fg,
                    ),
                  ),
                  Text(subtitle, style: RmText.mono(10.5, color: rm.fg3)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DiagonalStripePainter extends CustomPainter {
  const _DiagonalStripePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const gap = 14.0;
    for (double x = -size.height; x < size.width + size.height; x += gap) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
