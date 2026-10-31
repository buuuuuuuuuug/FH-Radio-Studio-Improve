import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

class RmSelect<T> extends StatelessWidget {
  const RmSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.selectedPrefix,
    this.horizontalPadding = 10,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final String? selectedPrefix;
  final double horizontalPadding;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      height: 32,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          iconSize: 14,
          dropdownColor: rm.panel,
          borderRadius: BorderRadius.circular(RmTokens.rSm),
          style: RmText.sans(12, color: rm.fg),
          selectedItemBuilder: selectedPrefix == null
              ? null
              : (context) => [
                  for (final label in items.values)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '$selectedPrefix · $label',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
          icon: Icon(Icons.expand_more, size: 14, color: rm.fg3),
          items: [
            for (final e in items.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(
                  e.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v != null) onChanged!(v);
                },
        ),
      ),
    );
  }
}
