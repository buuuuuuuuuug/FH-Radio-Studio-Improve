import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_icon.dart';

// Shared confirmation chrome used by the overview and resource deployment.
class StudioModalHead extends StatelessWidget {
  const StudioModalHead({
    super.key,
    required this.title,
    required this.eyebrow,
    this.overline,
    this.icon = 'check',
    this.danger = false,
  });

  final String title;
  final String eyebrow;
  final String? overline;
  final String icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone = danger ? rm.danger : rm.accent.base;
    final toneBg = danger ? rm.dangerBg : rm.accent.bg;
    final toneBorder = danger ? rm.danger.withAlpha(77) : rm.accent.ring;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: toneBg,
              border: Border.all(color: toneBorder),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: RmIcon(icon, size: 18, color: tone),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overline != null) ...[
                      Text(
                        overline!,
                        style: RmText.sans(
                          11,
                          color: tone,
                          weight: FontWeight.w600,
                        ),
                      ),
                      Container(
                        width: 3,
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: tone.withAlpha(150),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                    Text(
                      eyebrow,
                      style: RmText.mono(
                        10.5,
                        color: tone,
                        weight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: RmText.sans(17, color: rm.fg, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          RmButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const RmIcon('x', size: 13),
            variant: RmButtonVariant.ghost,
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

class StudioModalFoot extends StatelessWidget {
  const StudioModalFoot({
    super.key,
    required this.action,
    required this.danger,
    required this.enabled,
    required this.onConfirm,
    this.icon = 'check',
  });

  final String action;
  final bool danger;
  final bool enabled;
  final String icon;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RmButton(
            onPressed: () => Navigator.of(context).pop(),
            label: '取消',
            size: RmButtonSize.sm,
          ),
          const SizedBox(width: 8),
          RmButton(
            onPressed: enabled ? onConfirm : null,
            label: action,
            leading: RmIcon(icon, size: 12),
            size: RmButtonSize.sm,
            variant: danger
                ? RmButtonVariant.dangerPrimary
                : RmButtonVariant.primary,
          ),
        ],
      ),
    );
  }
}

class StudioChecklistItem extends StatelessWidget {
  const StudioChecklistItem({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.last = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: rm.border)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: rm.accent.base,
              side: BorderSide(color: rm.borderStrong),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: RmText.sans(13, color: rm.fg)),
            ),
          ],
        ),
      ),
    );
  }
}

class StudioModalFacts extends StatelessWidget {
  const StudioModalFacts({
    super.key,
    required this.rows,
    this.wrapValues = false,
  });

  final List<(String, String)> rows;
  final bool wrapValues;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rm.bg,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: wrapValues
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      row.$1,
                      style: RmText.mono(
                        10.5,
                        color: rm.fg3,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: wrapValues
                        ? SelectableText(
                            row.$2,
                            style: RmText.mono(
                              11.5,
                              color: rm.fg2,
                              letterSpacing: 0,
                            ),
                          )
                        : Text(
                            row.$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(
                              11.5,
                              color: rm.fg2,
                              letterSpacing: 0,
                            ),
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
