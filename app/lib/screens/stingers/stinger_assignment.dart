import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/assignment_radio_choice.dart';
import '../../widgets/assignment_shortcuts.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_select.dart';
import 'stinger_models.dart';

int? stingerFreeStart(Map<String, dynamic> station, int count) {
  final slots = stingerMaps(station['slots']);
  for (var i = 0; i + count <= slots.length; i++) {
    if (slots.skip(i).take(count).every((s) => s['assignment'] == null)) {
      return i + 1;
    }
  }
  return null;
}

class StingerAssignDialog extends StatefulWidget {
  const StingerAssignDialog({
    super.key,
    required this.stations,
    required this.count,
    required this.radio,
  });
  final List<Map<String, dynamic>> stations;
  final int count, radio;
  @override
  State<StingerAssignDialog> createState() => _StingerAssignDialogState();
}

class _StingerAssignDialogState extends State<StingerAssignDialog> {
  late int radio = widget.stations.any((s) => s['radio'] == widget.radio)
      ? widget.radio
      : widget.stations.first['radio'] as int;
  late int start = stingerFreeStart(station, widget.count) ?? 1;
  String? error;
  Map<String, dynamic> get station =>
      widget.stations.firstWhere((s) => s['radio'] == radio);
  void choose(int number) {
    setState(() {
      radio = number;
      start = stingerFreeStart(station, widget.count) ?? 1;
      error = null;
    });
    if (widget.count == 1) {
      if (stingerFreeStart(station, 1) != null) {
        finish();
      } else {
        setState(() => error = '此电台已满。可在下方指定位置替换，或先新增台呼位置。');
      }
    }
  }

  void finish() {
    if (start + widget.count - 1 > stingerMaps(station['slots']).length) {
      setState(() => error = '此电台位置不足，请选择其他电台或先新增台呼位置。');
      return;
    }
    Navigator.pop(context, {'radio': radio, 'start': start});
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final slots = stingerMaps(station['slots']);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (!assignmentKeyboardAvailable(context, event)) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          finish();
          return KeyEventResult.handled;
        }
        final shortcut = assignmentDigitShortcut(event, splitTypes: false);
        final number = int.tryParse(shortcut?.radio.substring(1) ?? '');
        if (number != null &&
            widget.stations.any((s) => s['radio'] == number)) {
          choose(number);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '分配台呼',
                  style: RmText.sans(20, color: rm.fg, weight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  assignmentShortcutHint(
                    splitTypes: false,
                    batch: widget.count > 1,
                  ),
                  style: RmText.sans(11.5, color: rm.fg3),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final s in widget.stations)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: AssignmentRadioChoice(
                              radio: RadioStation(
                                code: 'R${s['radio']}',
                                name: '${s['name']}',
                                hue: 'lime',
                                genre: '台呼',
                                slot: stingerMaps(s['slots']).length,
                              ),
                              summary:
                                  '${stingerMaps(s['slots']).where((slot) => slot['assignment'] == null).length} 个空位',
                              selected: radio == s['radio'],
                              onTap: () => choose(s['radio'] as int),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                RmSelect<int>(
                  value: start,
                  items: {
                    if (widget.count > slots.length) 1: '此电台位置不足',
                    for (var i = 1; i + widget.count - 1 <= slots.length; i++)
                      i: '从台呼 ${i.toString().padLeft(2, '0')} 开始',
                  },
                  onChanged: widget.count > slots.length
                      ? null
                      : (value) => setState(() => start = value),
                ),
                const SizedBox(height: 8),
                Text(
                  error ?? '默认使用空位；指定已有位置会替换原分配，可撤销。',
                  style: RmText.sans(
                    11.5,
                    color: error == null ? rm.fg3 : rm.warn,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    RmButton(
                      label: '取消',
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    RmButton(
                      label: '分配 ${widget.count} 个素材',
                      variant: RmButtonVariant.primary,
                      onPressed: finish,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
