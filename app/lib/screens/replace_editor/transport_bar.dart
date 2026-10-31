import '../../widgets/audio_play_button.dart';
import '../../widgets/editor_controls.dart';
import 'editor_timecode.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'replace_state.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.state,
    required this.aiPending,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onSkipFwd,
    this.floating = false,
    this.compact = false,
    this.trailing,
    this.onUndo,
    this.onRedo,
    this.actions = const [],
  });

  final ReplaceEditorState state;
  final bool aiPending;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onSkipFwd;
  final bool floating;

  /// 精简模式：人工选点面板里只保留传输键、时间码与 BPM，去掉段落标签和快捷键提示。
  final bool compact;

  /// 行尾追加的自定义控件（人工选点里放 A/B 端点切换）。
  final Widget? trailing;
  final VoidCallback? onUndo, onRedo;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final ai = state.ai;
    final durationText = ai.durationSec > 0
        ? formatEditorTimecode(ai.durationSec)
        : '--:--';

    if (compact) {
      return EditorTransport(
        playing: state.playing,
        onPlay: onTogglePlay,
        position: Text(
          '${formatEditorTimecode(state.playhead)} / $durationText',
          style: RmText.mono(13, color: rm.fg2),
        ),
        onUndo: onUndo,
        onRedo: onRedo,
        actions: [...actions, ?trailing],
      );
    }

    return Container(
      padding: EdgeInsets.all(compact ? 9 : 12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: floating ? rm.borderStrong : rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        boxShadow: floating ? RmTokens.popover : null,
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final controls = <Widget>[
            if (!compact) ...[
              RmButton.icon(
                onPressed: onRewind,
                icon: const RmIcon('skip-back', size: 12),
              ),
              const SizedBox(width: 8),
            ],
            _playButton(context),
            if (!compact) ...[
              const SizedBox(width: 8),
              RmButton.icon(
                onPressed: onSkipFwd,
                icon: const RmIcon('skip-fwd', size: 12),
              ),
            ],
            const SizedBox(width: 12),
            RichText(
              text: TextSpan(
                style: RmText.mono(13, color: rm.fg),
                children: [
                  TextSpan(text: formatEditorTimecode(state.playhead)),
                  TextSpan(
                    text: ' / $durationText',
                    style: RmText.mono(13, color: rm.fg3),
                  ),
                ],
              ),
            ),
          ];
          final details = <Widget>[
            if (!compact && c.maxWidth >= 480)
              Text(
                aiPending ? 'BPM --' : 'BPM ${ai.bpm.toStringAsFixed(1)}',
                style: RmText.mono(11, color: rm.fg3),
              ),
            if (!compact && c.maxWidth >= 480) ...[
              const SizedBox(width: 14),
              _kbd(context, 'Space'),
            ],
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ];
          return Row(
            children: [
              ...controls.take(controls.length - 1),
              Expanded(
                child: Align(
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: FittedBox(fit: BoxFit.scaleDown, child: controls.last),
                ),
              ),
              ...details,
            ],
          );
        },
      ),
    );
  }

  Widget _playButton(BuildContext context) {
    return AudioPlayButton(
      controlKey: ValueKey(
        floating ? 'editor-play-floating' : 'editor-play-inline',
      ),
      playing: state.playing,
      onPressed: onTogglePlay,
    );
  }

  Widget _kbd(BuildContext context, String label) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: RmText.mono(10.5, color: rm.fg2)),
    );
  }
}
