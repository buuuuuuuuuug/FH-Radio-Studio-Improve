import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';
import 'rm_field.dart';
import '../theme/tokens.dart';
import 'timing_dialog_frame.dart';

class BpmEditButton extends StatelessWidget {
  const BpmEditButton({
    super.key,
    required this.bpm,
    required this.manual,
    required this.onApply,
    this.enabled = true,
  });

  final double bpm;
  final bool manual;
  final bool enabled;
  final ValueChanged<double> onApply;

  @override
  Widget build(BuildContext context) => RmButton(
    label: 'BPM ${bpm.toStringAsFixed(1)}${manual ? ' · 手动' : ''}',
    tooltip: '修改 BPM',
    onPressed: enabled
        ? () async {
            final value = await showDialog<double>(
              context: context,
              barrierColor: RmTokens.modalBackdrop,
              builder: (_) => _BpmDialog(bpm: bpm),
            );
            if (value != null && context.mounted) onApply(value);
          }
        : null,
  );
}

class _BpmDialog extends StatefulWidget {
  const _BpmDialog({required this.bpm});
  final double bpm;
  @override
  State<_BpmDialog> createState() => _BpmDialogState();
}

class _BpmDialogState extends State<_BpmDialog> {
  late final _value = TextEditingController(
    text: widget.bpm.toStringAsFixed(3),
  );
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _scale(double factor) {
    final current = double.tryParse(_value.text.trim());
    if (current != null && current.isFinite) {
      _value.text = (current * factor).toStringAsFixed(3);
    }
  }

  void _apply() {
    final value = double.tryParse(_value.text.trim());
    if (value == null || !value.isFinite || value < 20 || value > 400) {
      setState(() => _error = '请输入 20–400 之间的 BPM，可填小数。');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return TimingDialogFrame(
      title: '修改 BPM',
      icon: 'settings',
      description: '校准拍线与按拍微调的步长',
      busy: false,
      width: 480,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('每分钟节拍数', style: RmText.sans(12, color: rm.fg2)),
          const SizedBox(height: 8),
          TextField(
            controller: _value,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: RmText.statValue(color: rm.fg),
            decoration: rmFieldDecoration(context, error: _error).copyWith(
              suffixText: 'BPM',
              suffixStyle: RmText.mono(12, color: rm.fg3),
              contentPadding: const EdgeInsets.all(14),
            ),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              RmButton(label: '减半', onPressed: () => _scale(.5)),
              RmButton(label: '加倍', onPressed: () => _scale(2)),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '已选时间点的位置保持不变。若检测为半速或倍速，可使用上方按钮校准。',
            style: RmText.body(color: rm.fg3),
          ),
          const SizedBox(height: 10),
          Text(
            '应用后请点击歌曲页「保存」；重新分析会保留手动 BPM。',
            style: RmText.body(color: rm.fg3),
          ),
        ],
      ),
      actions: [
        RmButton(label: '取消', onPressed: () => Navigator.of(context).pop()),
        RmButton(
          label: '应用 BPM',
          variant: RmButtonVariant.primary,
          onPressed: _apply,
        ),
      ],
    );
  }
}
