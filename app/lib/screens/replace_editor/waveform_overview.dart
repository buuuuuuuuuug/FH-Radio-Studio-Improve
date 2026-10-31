import '../../widgets/rm_tooltip.dart';
import '../../domain/replacement_models.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'waveform_painter.dart';

/// Full-song navigation for a zoomed waveform; never edits markers or seeks audio.
class WaveformOverview extends StatefulWidget {
  const WaveformOverview({
    super.key,
    required this.bars,
    required this.duration,
    required this.windowStart,
    required this.windowEnd,
    required this.onWindowStart,
    this.height = 38,
  });
  final WaveformBars bars;
  final double duration, windowStart, windowEnd;
  final double height;
  final ValueChanged<double> onWindowStart;
  @override
  State<WaveformOverview> createState() => _WaveformOverviewState();
}

class _WaveformOverviewState extends State<WaveformOverview> {
  double? _dragX;
  double _dragStart = 0;
  double get _span => (widget.windowEnd - widget.windowStart).clamp(
    0.0,
    widget.duration > 0 ? widget.duration : 0,
  );
  bool get _enabled =>
      widget.duration > 0 && _span > 0 && _span < widget.duration;
  void _move(double start) {
    if (!_enabled) return;
    widget.onWindowStart(start.clamp(0.0, widget.duration - _span));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: widget.height,
    child: LayoutBuilder(
      builder: (context, c) {
        final scale = c.maxWidth > 0 ? widget.duration / c.maxWidth : 0.0;
        return RmTooltip(
          message: '全曲概览 · 高亮框为当前范围；点击或拖动查看其他位置',
          child: MouseRegion(
            cursor: _enabled
                ? SystemMouseCursors.grab
                : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _move(d.localPosition.dx * scale - _span / 2),
              onHorizontalDragStart: (d) {
                if (!_enabled) return;
                _dragX = d.globalPosition.dx;
                final time = d.localPosition.dx * scale;
                _dragStart =
                    time >= widget.windowStart && time <= widget.windowEnd
                    ? widget.windowStart
                    : (time - _span / 2).clamp(0.0, widget.duration - _span);
                _move(_dragStart);
              },
              onHorizontalDragUpdate: (d) {
                if (_dragX != null) {
                  _move(_dragStart + (d.globalPosition.dx - _dragX!) * scale);
                }
              },
              onHorizontalDragEnd: (_) => _dragX = null,
              onHorizontalDragCancel: () => _dragX = null,
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size(c.maxWidth, widget.height),
                  painter: ZoomStripPainter(
                    rm: context.rm,
                    bars: widget.bars,
                    duration: widget.duration,
                    windowStart: widget.windowStart,
                    windowEnd: widget.windowEnd,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
