import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';
import 'rm_icon.dart';
import 'audio_play_button.dart';
import '../theme/tokens.dart';

class EditorHistoryButtons extends StatelessWidget {
  const EditorHistoryButtons({
    super.key,
    this.onUndo,
    this.onRedo,
    this.undoHint = '撤销 · Ctrl+Z',
    this.redoHint = '重做 · Ctrl+Y',
  });
  final VoidCallback? onUndo, onRedo;
  final String undoHint, redoHint;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      RmButton.icon(
        key: const ValueKey('editor-history-undo'),
        icon: const RmIcon('undo', size: 13),
        tooltip: undoHint,
        onPressed: onUndo,
      ),
      const SizedBox(width: 6),
      RmButton.icon(
        key: const ValueKey('editor-history-redo'),
        icon: const RmIcon('redo', size: 13),
        tooltip: redoHint,
        onPressed: onRedo,
      ),
    ],
  );
}

/// Shared waveform frame used by song, stinger and voice editors.
class EditorWaveformPanel extends StatelessWidget {
  const EditorWaveformPanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: context.rm.panel,
      border: Border.all(color: context.rm.border),
      borderRadius: BorderRadius.circular(RmTokens.rLg),
    ),
    child: child,
  );
}

/// Playback on the left; edit history directly before the first edit action.
class EditorTransport extends StatelessWidget {
  const EditorTransport({
    super.key,
    required this.playing,
    required this.onPlay,
    required this.position,
    this.onUndo,
    this.onRedo,
    this.actions = const [],
    this.inlineBreakpoint = 740,
    this.undoHint = '撤销 · Ctrl+Z',
    this.redoHint = '重做 · Ctrl+Y',
    this.playKey,
  });
  final bool playing;
  final VoidCallback? onPlay, onUndo, onRedo;
  final Widget position;
  final List<Widget> actions;
  final double inlineBreakpoint;
  final String undoHint, redoHint;
  final Key? playKey;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: context.rm.panel,
      border: Border.all(color: context.rm.border),
      borderRadius: BorderRadius.circular(RmTokens.rLg),
    ),
    child: LayoutBuilder(
      builder: (context, box) {
        final playback = Row(
          children: [
            AudioPlayButton(
              controlKey: playKey,
              playing: playing,
              onPressed: onPlay,
            ),
            const SizedBox(width: 10),
            Expanded(child: position),
          ],
        );
        final controls = Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                EditorHistoryButtons(
                  onUndo: onUndo,
                  onRedo: onRedo,
                  undoHint: undoHint,
                  redoHint: redoHint,
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  actions.first,
                ],
              ],
            ),
            ...actions.skip(1),
          ],
        );
        if (box.maxWidth >= inlineBreakpoint) {
          return Row(
            children: [
              Expanded(child: playback),
              const SizedBox(width: 12),
              controls,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            playback,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: controls),
          ],
        );
      },
    ),
  );
}

/// The original precision editor's hint chips, shared by audio editors.
class EditorShortcutHints extends StatelessWidget {
  const EditorShortcutHints({super.key, required this.hints});
  final List<String> hints;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      RmIcon('info', size: 14, color: context.rm.fg3),
      const SizedBox(width: 8),
      Expanded(
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final hint in hints)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: context.rm.raised,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  hint,
                  style: RmText.sans(11, color: context.rm.fg2),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// Original repeat-on-hold precision buttons. The unit stays beside the pair.
class EditorNudgePair extends StatelessWidget {
  const EditorNudgePair({
    super.key,
    required this.minus,
    required this.plus,
    required this.onMinus,
    required this.onPlus,
    this.unit,
  });
  final String minus, plus;
  final VoidCallback? onMinus, onPlus;
  final String? unit;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      RmButton(
        repeat: true,
        size: RmButtonSize.sm,
        label: minus,
        tooltip: '长按约 0.5 秒后连续调整，松开即停止',
        onPressed: onMinus,
      ),
      const SizedBox(width: 4),
      RmButton(
        repeat: true,
        size: RmButtonSize.sm,
        label: plus,
        tooltip: '长按约 0.5 秒后连续调整，松开即停止',
        onPressed: onPlus,
      ),
      if (unit != null) ...[
        const SizedBox(width: 5),
        Text(unit!, style: RmText.mono(11, color: context.rm.fg4)),
      ],
    ],
  );
}
