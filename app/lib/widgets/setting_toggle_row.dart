import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';

/// The compact option row used by the overview's basic editor settings.
class SettingToggleRow extends StatelessWidget {
  const SettingToggleRow({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  });
  final String title, description;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RmText.sans(
                    12.5,
                    weight: FontWeight.w500,
                    color: rm.fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(description, style: RmText.sans(11.5, color: rm.fg3)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 40,
            height: 24,
            child: FittedBox(
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: rm.panel,
                activeTrackColor: rm.accent.base,
                inactiveThumbColor: rm.fg4,
                inactiveTrackColor: rm.raised,
                trackOutlineColor: WidgetStateProperty.all(rm.border),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
