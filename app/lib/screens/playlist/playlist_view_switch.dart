import 'package:flutter/material.dart';
import '../../state/playlist_catalog_state.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';

class PlaylistViewSwitch extends StatelessWidget {
  const PlaylistViewSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PlaylistCatalogView value;
  final ValueChanged<PlaylistCatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: rm.raised,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: rm.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, PlaylistCatalogView.game, '游戏内'),
          _segment(context, PlaylistCatalogView.package, '准备包'),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    PlaylistCatalogView option,
    String label,
  ) {
    final rm = context.rm;
    final active = option == value;
    final accent = option == PlaylistCatalogView.package
        ? rm.accent.base
        : rm.info;
    final activeBg = option == PlaylistCatalogView.package
        ? Color.alphaBlend(rm.accent.base.withAlpha(16), rm.hover)
        : Color.alphaBlend(rm.info.withAlpha(14), rm.hover);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(option),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: active ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: RmText.sans(
              12,
              color: active ? accent : rm.fg3,
              weight: active ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
