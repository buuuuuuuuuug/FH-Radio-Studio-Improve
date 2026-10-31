import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_icon.dart';
import 'rm_chip.dart';

class PlaylistSearchField extends StatelessWidget {
  const PlaylistSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = '搜索歌曲 / 歌手 / 文件名',
    this.fieldKey,
    this.clearKey,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final Key? fieldKey, clearKey;
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(RmTokens.rSm),
      borderSide: BorderSide(color: color),
    );
    return SizedBox(
      height: 38,
      child: TextField(
        key: fieldKey,
        controller: controller,
        onChanged: onChanged,
        style: RmText.sans(12.5, color: rm.fg),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: RmText.sans(12.5, color: rm.fg4),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 8),
            child: RmIcon('search', size: 13, color: rm.fg3),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  key: clearKey,
                  tooltip: '清空搜索',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: RmIcon('x', size: 14, color: rm.fg3),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          suffixIconConstraints: const BoxConstraints.tightFor(
            width: 32,
            height: 32,
          ),
          isDense: true,
          filled: true,
          fillColor: rm.raised,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 9,
          ),
          border: border(rm.border),
          enabledBorder: border(rm.border),
          focusedBorder: border(rm.accent.base),
        ),
      ),
    );
  }
}

/// Keep the search and legend shared across song and stinger boards.
class PlaylistSearchRow extends StatelessWidget {
  const PlaylistSearchRow({super.key, required this.search});
  final Widget search;
  @override
  Widget build(BuildContext context) {
    const legend = Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        RmChip(
          label: 'custom · 自建',
          variant: RmChipVariant.accent,
          showDot: true,
        ),
        RmChip(
          label: 'builtin · 锁定',
          variant: RmChipVariant.muted,
          leading: RmIcon('lock', size: 10),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 480
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [search, const SizedBox(height: 8), legend],
            )
          : Row(
              children: [
                Expanded(child: search),
                const SizedBox(width: 10),
                legend,
              ],
            ),
    );
  }
}
