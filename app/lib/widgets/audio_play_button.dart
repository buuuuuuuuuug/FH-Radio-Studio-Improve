import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'rm_icon.dart';

/// The editor transport's play control, shared with the stinger workbench.
class AudioPlayButton extends StatelessWidget {
  const AudioPlayButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.controlKey,
  });
  final bool playing;
  final VoidCallback? onPressed;
  final Key? controlKey;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: onPressed == null
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
    child: GestureDetector(
      key: controlKey,
      onTap: onPressed,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: context.rm.accent.base,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: RmIcon(
          playing ? 'pause' : 'play',
          size: 16,
          color: context.rm.accent.onAccent,
        ),
      ),
    ),
  );
}
