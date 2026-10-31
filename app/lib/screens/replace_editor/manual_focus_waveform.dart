import 'package:flutter/services.dart';
import 'editor_timecode.dart';
import '../../widgets/waveform_zoom_gesture.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../domain/replacement_models.dart';
import '../../domain/waveform_envelope.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';

/// 精修台里的一个可放置端点（单点组只有一个；循环组有 A / B 两个）。
class FocusHandle {
  const FocusHandle({
    required this.key,
    required this.t,
    required this.label,
    required this.active,
    this.dim = false,
  });

  final String key;
  final double t;
  final String label;

  /// 当前正在编辑的端点（放大、加光晕）。
  final bool active;

  /// 非激活的循环端点（淡化到 45%）。
  final bool dim;
}

/// 精修台主波形 —— 直接点 / 拖波形放置时间点。
///
/// 与 [WaveformCard] 不同，这里：
/// * 只画当前时间组的 1 个或 2 个端点，而不是全部 6 个 marker；
/// * 顶部带段落泳道、每拍网格线（downbeat 更重）、循环阴影带；
/// * 端点是可拖拽的旗标 + 立柱 + 抓手，激活态放大、非激活态淡化；
/// * 指针在波形上按下挑最近端点、拖动即移动，磁吸交给父级处理。
class ManualFocusWaveform extends StatefulWidget {
  const ManualFocusWaveform({
    super.key,
    required this.bars,
    required this.beats,
    required this.segments,
    required this.duration,
    required this.accent,
    required this.handles,
    required this.free,
    required this.locked,
    required this.onPlace,
    this.playhead,
    this.canvasHeight = 132,
    this.windowStart = 0,
    this.windowEnd,
    this.onZoom,
    this.onViewportWidth,
    this.onQuickConfirm,
    this.onSeek,
    this.onSelection,
    this.selectionStart,
    this.selectionEnd,
    this.timeGrid = false,
  });

  final WaveformBars bars;
  final List<double> beats;
  final List<Segment> segments;
  final double duration;
  final Color accent;
  final List<FocusHandle> handles;

  /// 是否处于自由放置（按住自由放置快捷键）：影响光标提示。
  final bool free;

  /// 锁定后波形拒绝放点。
  final bool locked;

  /// 试听时的播放头位置（秒），null 表示不画。
  final double? playhead;

  final double canvasHeight;
  final double windowStart;
  final double? windowEnd;
  final ValueChanged<double>? onZoom;
  final ValueChanged<double>? onViewportWidth;
  final VoidCallback? onQuickConfirm;
  final ValueChanged<double>? onSeek;
  final void Function(double start, double end)? onSelection;
  final double? selectionStart, selectionEnd;
  final bool timeGrid;

  /// 放点回调。[isMove] 区分按下（挑最近端点）与拖动（沿用当前端点）。
  final void Function(double seconds, {required bool isMove}) onPlace;

  @override
  State<ManualFocusWaveform> createState() => _ManualFocusWaveformState();
}

class _ManualFocusWaveformState extends State<ManualFocusWaveform> {
  double get _flagPad => widget.handles.isEmpty ? 4 : 20;

  double? _width;
  bool _dragging = false;
  bool _seeking = false;
  double? _selectionAnchor;

  double get _end => widget.windowEnd ?? widget.duration;
  double get _span => math.max(0.001, _end - widget.windowStart);

  double _timeAt(double dx) {
    final w = _width ?? 1;
    final pct = (dx / w).clamp(0.0, 1.0);
    return widget.windowStart + pct * _span;
  }

  void _down(PointerDownEvent e) {
    if (widget.locked) return;
    if (e.buttons == 1) {
      _seeking = true;
      widget.onSeek?.call(_timeAt(e.localPosition.dx));
      return;
    }
    if (e.buttons == 2 &&
        HardwareKeyboard.instance.isControlPressed &&
        widget.onQuickConfirm != null) {
      widget.onQuickConfirm?.call();
      return;
    }
    if (e.buttons != 2) return;
    _dragging = true;
    final time = _timeAt(e.localPosition.dx);
    if (widget.onSelection != null) {
      _selectionAnchor = time;
      widget.onSelection!(time, time);
    } else {
      widget.onPlace(time, isMove: false);
    }
  }

  void _move(PointerMoveEvent e) {
    if (widget.locked) return;
    final time = _timeAt(e.localPosition.dx);
    if (_seeking) widget.onSeek?.call(time);
    if (!_dragging) return;
    if (_selectionAnchor != null) {
      widget.onSelection!(_selectionAnchor!, time);
    } else {
      widget.onPlace(time, isMove: true);
    }
  }

  void _up(PointerUpEvent _) {
    _dragging = false;
    _seeking = false;
    _selectionAnchor = null;
  }

  MouseCursor get _cursor {
    if (widget.locked) return SystemMouseCursors.forbidden;
    if (widget.free) return SystemMouseCursors.cell;
    return SystemMouseCursors.precise;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        WaveformZoomGesture(
          onZoom: widget.onZoom,
          child: SizedBox(
            height: _flagPad + widget.canvasHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                widget.onViewportWidth?.call(c.maxWidth);
                _width = c.maxWidth;
                final w = c.maxWidth;
                return MouseRegion(
                  cursor: _cursor,
                  child: Listener(
                    onPointerDown: _down,
                    onPointerMove: _move,
                    onPointerUp: _up,
                    onPointerCancel: (_) => _up(const PointerUpEvent()),
                    behavior: HitTestBehavior.opaque,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _FocusWavePainter(
                              rm: rm,
                              bars: widget.bars,
                              beats: widget.beats,
                              duration: widget.duration,
                              windowStart: widget.windowStart,
                              windowEnd: _end,
                              accent: widget.accent,
                              handles: widget.handles,
                              topPad: _flagPad,
                              barsHeight: widget.canvasHeight,
                              timeGrid: widget.timeGrid,
                              selectionStart: widget.selectionStart,
                              selectionEnd: widget.selectionEnd,
                            ),
                          ),
                        ),
                        for (final h in widget.handles)
                          if (h.t >= widget.windowStart && h.t <= _end)
                            _handle(rm, h, w),
                        if (widget.playhead != null &&
                            widget.playhead! >= widget.windowStart &&
                            widget.playhead! <= _end)
                          _playheadLine(rm, w),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        _timeAxis(rm),
      ],
    );
  }

  // --- 端点旗标 ----------------------------------------------------------
  Widget _handle(RmTheme rm, FocusHandle h, double w) {
    final x = ((h.t - widget.windowStart) / _span).clamp(0.0, 1.0) * w;
    final opacity = h.dim ? 0.45 : 1.0;
    final gripSize = h.active ? 20.0 : 16.0;
    return Positioned(
      left: x - 40,
      top: 0,
      bottom: 0,
      width: 80,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              // 旗标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.accent,
                  borderRadius: BorderRadius.circular(4),
                  border: h.active
                      ? Border.all(color: rm.panel, width: 1.5)
                      : null,
                ),
                child: Text(
                  h.label,
                  style: RmText.mono(
                    10,
                    weight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              // 立柱
              Expanded(child: Container(width: 2, color: widget.accent)),
              // 抓手
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  width: gripSize,
                  height: gripSize,
                  decoration: BoxDecoration(
                    color: rm.panel,
                    shape: BoxShape.circle,
                    border: Border.all(color: widget.accent, width: 2),
                    boxShadow: h.active
                        ? [
                            BoxShadow(
                              color: widget.accent.withAlpha(64),
                              blurRadius: 6,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playheadLine(RmTheme rm, double w) {
    final x =
        ((widget.playhead! - widget.windowStart) / _span).clamp(0.0, 1.0) * w;
    return Positioned(
      left: x - 0.75,
      top: _flagPad - 2,
      bottom: 0,
      width: 1.5,
      child: IgnorePointer(child: ColoredBox(color: rm.fg)),
    );
  }

  // --- 时间轴 ------------------------------------------------------------
  Widget _timeAxis(RmTheme rm) {
    return LayoutBuilder(
      builder: (context, box) {
        final style = RmText.mono(9.5, color: rm.fg4);
        if (widget.timeGrid) {
          final grid = WaveformTimeGrid(_span, box.maxWidth);
          final step = grid.labelStep;
          return SizedBox(
            height: 14,
            child: Stack(
              children: [
                for (
                  var i = (widget.windowStart / step).ceil();
                  i * step <= _end + .000001;
                  i++
                )
                  _gridLabel(i * step, box.maxWidth, style),
              ],
            ),
          );
        }
        final label = TextPainter(
          text: TextSpan(text: _shortLabel(_end), style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final intervals = ((box.maxWidth / (label.width + 10)).floor() - 1)
            .clamp(1, 5);
        return Row(
          children: [
            for (int i = 0; i <= intervals; i++) ...[
              if (i != 0) const Spacer(),
              SizedBox(
                width: math.min(label.width, box.maxWidth / (intervals + 1)),
                child: Text(
                  _shortLabel(widget.windowStart + _span * i / intervals),
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _gridLabel(double time, double width, TextStyle style) {
    final text = _shortLabel(time);
    final measured = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final x = (time - widget.windowStart) / _span * width;
    final atStart = x.abs() < .01;
    final atEnd = (x - width).abs() < .01;
    final left = atStart
        ? 0.0
        : atEnd
        ? width - measured.width
        : x - measured.width / 2;
    if (!atStart && !atEnd && (left < 0 || left + measured.width > width)) {
      return const SizedBox.shrink();
    }
    return Positioned(
      key: ValueKey('wave-time-${time.toStringAsFixed(6)}'),
      left: left,
      width: measured.width,
      child: Text(text, style: style, maxLines: 1),
    );
  }
}

String _shortLabel(double t) => formatEditorTimecode(t);

class _FocusWavePainter extends CustomPainter {
  _FocusWavePainter({
    required this.rm,
    required this.bars,
    required this.beats,
    required this.duration,
    required this.accent,
    required this.handles,
    required this.topPad,
    required this.barsHeight,
    required this.windowStart,
    required this.windowEnd,
    this.timeGrid = false,
    this.selectionStart,
    this.selectionEnd,
  });

  final RmTheme rm;
  final WaveformBars bars;
  final List<double> beats;
  final double duration;
  final Color accent;
  final List<FocusHandle> handles;
  final double topPad;
  final double barsHeight;
  final double windowStart, windowEnd;
  final bool timeGrid;
  final double? selectionStart, selectionEnd;

  double _x(double t, double width) =>
      ((t - windowStart) / math.max(0.001, windowEnd - windowStart)) * width;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final width = size.width;
    canvas.clipRect(Offset.zero & size);
    final centerY = topPad + barsHeight / 2;
    if (selectionStart != null && selectionEnd != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          _x(selectionStart!, width),
          topPad,
          _x(selectionEnd!, width),
          topPad + barsHeight,
        ),
        Paint()..color = accent.withAlpha(35),
      );
    }
    if (timeGrid) {
      final step = WaveformTimeGrid(windowEnd - windowStart, width).minorStep;
      for (
        var i = (windowStart / step).ceil();
        i * step <= windowEnd + .000001;
        i++
      ) {
        final major = i % 5 == 0;
        final x = _x(i * step, width);
        canvas.drawLine(
          Offset(x, topPad),
          Offset(x, topPad + barsHeight),
          Paint()
            ..color = major
                ? rm.borderStrong.withAlpha(145)
                : rm.border.withAlpha(125)
            ..strokeWidth = major ? 1 : .5,
        );
      }
    }

    // 循环阴影带（A→B）
    if (handles.length == 2) {
      final a = _x(handles[0].t, width);
      final b = _x(handles[1].t, width);
      canvas.drawRect(
        Rect.fromLTRB(
          a < b ? a : b,
          topPad,
          a < b ? b : a,
          topPad + barsHeight,
        ),
        Paint()..color = accent.withAlpha(30),
      );
    }

    // 每拍网格线（downbeat 更重）
    if (beats.isNotEmpty) {
      for (int i = 0; i < beats.length; i++) {
        if (beats[i] < windowStart || beats[i] > windowEnd) continue;
        final x = _x(beats[i], width);
        final down = i % 4 == 0;
        canvas.drawLine(
          Offset(x, topPad),
          Offset(x, topPad + barsHeight),
          Paint()
            ..color = (down ? rm.borderStrong : rm.border2).withAlpha(
              down ? 128 : 72,
            )
            ..strokeWidth = down ? 1 : 0.6,
        );
      }
    }

    // 中线
    canvas.drawLine(
      Offset(0, centerY),
      Offset(width, centerY),
      Paint()
        ..color = rm.border
        ..strokeWidth = 0.6,
    );

    // 波形 bars（中线对称）
    final values = waveformDisplayEnvelope(
      bars.values,
      duration: duration,
      windowStart: windowStart,
      windowEnd: windowEnd,
      maximumBars: math.max(512, (width / 4).ceil()),
    );
    if (values.isNotEmpty) {
      final barPaint = Paint()..color = rm.fg3.withAlpha(200);
      final n = values.length;
      final barWidth = width / n * 0.74;
      for (int i = 0; i < n; i++) {
        final h = values[i] * (barsHeight / 2 - 4);
        final x = n == 1 ? width / 2 : (i / (n - 1)) * width;
        canvas.drawRect(
          Rect.fromLTWH(x - barWidth / 2, centerY - h, barWidth, h * 2),
          barPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FocusWavePainter old) =>
      old.bars != bars ||
      old.beats != beats ||
      old.duration != duration ||
      old.windowStart != windowStart ||
      old.windowEnd != windowEnd ||
      old.accent != accent ||
      old.handles != handles ||
      old.timeGrid != timeGrid ||
      old.selectionStart != selectionStart ||
      old.selectionEnd != selectionEnd ||
      old.rm != rm ||
      old.barsHeight != barsHeight;
}

class WaveformTimeGrid {
  WaveformTimeGrid(double span, double width) {
    final pixelsPerSecond = math.max(1, width) / math.max(.00001, span);
    var minor = .1;
    while (minor * pixelsPerSecond < 6) {
      minor *= 10;
    }
    while (minor * pixelsPerSecond > 60 && minor > .00001) {
      minor /= 10;
    }
    minorStep = minor;
    var label = minor * 5;
    while (label * pixelsPerSecond < 80) {
      label *= 2;
    }
    labelStep = label;
  }
  late final double minorStep, labelStep;
}
