import 'editor_timecode.dart';
import '../../widgets/waveform_zoom_gesture.dart';
import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'ai_pending_overlay.dart';
import 'replace_state.dart';
import 'waveform_painter.dart';

/// 波形卡片 — 包 toolbar + 主波形 + zoom strip。
class WaveformCard extends StatefulWidget {
  const WaveformCard({
    super.key,
    required this.state,
    required this.aiPending,
    required this.onSeek,
    required this.onZoomIn,
    required this.onZoomOut,
    this.compact = false,
    this.onWheelZoom,
    this.onViewportWidth,
  });

  final ReplaceEditorState state;
  final bool aiPending;
  final ValueChanged<double> onSeek;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final ValueChanged<double>? onWheelZoom;
  final ValueChanged<double>? onViewportWidth;

  /// 精简模式：用于人工选点面板，去掉无关的视图切换 toolbar 与 zoom 概览条，
  /// 只保留可点选的波形和时间轴。
  final bool compact;

  @override
  State<WaveformCard> createState() => _WaveformCardState();
}

class _WaveformCardState extends State<WaveformCard> {
  bool _showWaveform = true;
  bool _showBeats = true;
  ReplaceEditorState get state => widget.state;
  bool get compact => widget.compact;
  bool get aiPending => widget.aiPending;
  ValueChanged<double> get onSeek => widget.onSeek;
  VoidCallback get onZoomIn => widget.onZoomIn;
  VoidCallback get onZoomOut => widget.onZoomOut;
  ValueChanged<double>? get onWheelZoom => widget.onWheelZoom;

  @override
  void didUpdateWidget(covariant WaveformCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.trackId != state.trackId) {
      _showWaveform = _showBeats = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final ai = state.ai;
    final bars = ai.waveformPeaks.isEmpty
        ? WaveformBars.build(segments: ai.segments, duration: ai.durationSec)
        : WaveformBars.fromValues(ai.waveformPeaks);
    final markers = <WaveformMarker>[
      WaveformMarker(t: state.td.t, label: 'TD', kind: GroupKind.td),
      WaveformMarker(t: state.pd.t, label: 'PD', kind: GroupKind.pd),
      WaveformMarker(t: state.tl.start, label: 'TL-A', kind: GroupKind.tl),
      WaveformMarker(t: state.tl.end, label: 'TL-B', kind: GroupKind.tl),
      WaveformMarker(t: state.pl.start, label: 'PL-A', kind: GroupKind.pl),
      WaveformMarker(t: state.pl.end, label: 'PL-B', kind: GroupKind.pl),
    ];

    final card = Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) _toolbar(context),
          Padding(
            padding: EdgeInsets.fromLTRB(14, compact ? 10 : 12, 14, 0),
            child: WaveformZoomGesture(
              onZoom: onWheelZoom,
              child: _waveformArea(context, bars: bars, markers: markers),
            ),
          ),
          _timeAxis(context, ai.durationSec),
          if (compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Text(
                'Ctrl + 滚轮缩放',
                textAlign: TextAlign.right,
                style: RmText.sans(10, color: rm.fg3),
              ),
            ),
          if (!compact) ...[
            Container(height: 1, color: rm.border),
            _zoom(context, bars: bars),
          ],
        ],
      ),
    );
    return AiPendingGate(
      pending:
          aiPending ||
          (state.track.id.startsWith('real:') &&
              ai.waveformPeaks.isEmpty &&
              state.error == null),
      overlayKey: const ValueKey('editor-ai-pending-waveform'),
      label: aiPending ? '波形分析中' : '正在读取波形',
      detail: aiPending ? '等待真实波形、节拍和时间点。' : '首次生成后自动缓存，再次打开直接读取。',
      blockInput: false,
      childOpacity: 0.42,
      child: card,
    );
  }

  Widget _toolbar(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final views = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _segGroup(context, [
                (
                  '波形',
                  _showWaveform,
                  () => setState(() => _showWaveform = !_showWaveform),
                ),
                (
                  '节拍',
                  _showBeats,
                  () => setState(() => _showBeats = !_showBeats),
                ),
              ]),
            ],
          );
          final playbackAndZoom = Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Ctrl + 滚轮缩放', style: RmText.sans(10, color: rm.fg3)),
                  const SizedBox(width: 8),
                  RmButton.icon(
                    onPressed: onZoomOut,
                    icon: const RmIcon('zoom-out', size: 12),
                    tooltip: '缩小波形',
                  ),
                  const SizedBox(width: 6),
                  RmButton.icon(
                    onPressed: onZoomIn,
                    icon: const RmIcon('zoom-in', size: 12),
                    tooltip: '放大波形',
                  ),
                ],
              ),
            ],
          );
          if (constraints.maxWidth >= 620) {
            return Row(children: [views, const Spacer(), playbackAndZoom]);
          }
          return Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [views, playbackAndZoom],
          );
        },
      ),
    );
  }

  Widget _segGroup(
    BuildContext context,
    List<(String, bool, VoidCallback)> items,
  ) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in items)
            Tooltip(
              message: i.$1 == '节拍' && state.ai.beats.isEmpty
                  ? '暂无检测节拍；可运行节拍分析后查看'
                  : '显示 / 隐藏${i.$1}',
              child: InkWell(
                key: ValueKey('waveform-toggle-${i.$1}'),
                onTap: i.$3,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: i.$2 ? rm.hover : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    i.$1,
                    style: RmText.mono(11, color: i.$2 ? rm.fg : rm.fg3),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _waveformArea(
    BuildContext context, {
    required WaveformBars bars,
    required List<WaveformMarker> markers,
  }) {
    final rm = context.rm;
    final ai = state.ai;
    return LayoutBuilder(
      builder: (context, c) {
        widget.onViewportWidth?.call(c.maxWidth);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            final pct = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
            onSeek(state.zoomStart + pct * (state.zoomEnd - state.zoomStart));
          },
          onHorizontalDragUpdate: (d) {
            final pct = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
            onSeek(state.zoomStart + pct * (state.zoomEnd - state.zoomStart));
          },
          onTapDown: (d) {
            final pct = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
            onSeek(state.zoomStart + pct * (state.zoomEnd - state.zoomStart));
          },
          child: SizedBox(
            height: WaveformPainter.heightForWindow(
              const [],
              state.zoomStart,
              state.zoomEnd,
            ),
            width: c.maxWidth,
            child: CustomPaint(
              painter: WaveformPainter(
                rm: rm,
                bars: bars,
                beats: _showBeats ? ai.beats : const [],
                segments: const [],
                showWaveform: _showWaveform,
                duration: ai.durationSec,
                markers: markers,
                tlLoop: (start: state.tl.start, end: state.tl.end),
                plLoop: (start: state.pl.start, end: state.pl.end),
                playhead: state.playhead,
                windowStart: state.zoomStart,
                windowEnd: state.zoomEnd,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _timeAxis(BuildContext context, double duration) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        children: [
          for (int i = 0; i <= 4; i++) ...[
            if (i != 0) const Spacer(),
            Text(
              _short(
                state.zoomStart + (state.zoomEnd - state.zoomStart) * i / 4,
              ),
              style: RmText.mono(10, color: rm.fg4),
            ),
          ],
        ],
      ),
    );
  }

  String _short(double t) => formatEditorTimecode(t);

  Widget _zoom(BuildContext context, {required WaveformBars bars}) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      height: 56,
      child: LayoutBuilder(
        builder: (context, c) {
          return CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: ZoomStripPainter(
              rm: rm,
              bars: bars,
              duration: state.ai.durationSec,
              windowStart: state.zoomStart,
              windowEnd: state.zoomEnd,
            ),
          );
        },
      ),
    );
  }
}
