import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';

/// The playlist's selection buttons, shared by all media pools and lists.
class PoolSelectionActions extends StatelessWidget {
  const PoolSelectionActions({
    super.key,
    required this.count,
    this.label,
    required this.onSelectAll,
    required this.onClear,
    this.actions = const [],
  });
  final int count;
  final String? label;
  final VoidCallback? onSelectAll, onClear;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final selection = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          label ?? '已选 $count',
          style: RmText.sans(10.5, color: context.rm.fg3),
        ),
        RmButton(
          size: RmButtonSize.sm,
          horizontalPadding: 6,
          label: '全选',
          onPressed: onSelectAll,
        ),
        RmButton(
          size: RmButtonSize.sm,
          horizontalPadding: 6,
          label: '清空',
          onPressed: onClear,
        ),
      ],
    );
    final commands = Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: actions,
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 220 + (actions.length > 1 ? 32 : 0)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              selection,
              if (actions.isNotEmpty) ...[const SizedBox(height: 6), commands],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: selection),
            if (actions.isNotEmpty) ...[const SizedBox(width: 6), commands],
          ],
        );
      },
    );
  }
}
