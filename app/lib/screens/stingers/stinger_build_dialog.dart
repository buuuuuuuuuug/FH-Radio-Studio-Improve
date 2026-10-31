import '../../widgets/timing_dialog_frame.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_chip.dart';
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_select.dart';
import '../../widgets/rm_slider.dart';
import 'stinger_models.dart';

class StingerBuildDialog extends StatefulWidget {
  const StingerBuildDialog({
    super.key,
    required this.stations,
    required this.initialGain,
    required this.quality,
    required this.restoredRadios,
    required this.preview,
    required this.play,
    required this.stop,
  });
  final List<Map<String, dynamic>> stations;
  final double initialGain;
  final int quality;
  final List<String> restoredRadios;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> edit)
  preview;
  final Future<void> Function(Map<String, dynamic> audio) play;
  final Future<void> Function() stop;
  @override
  State<StingerBuildDialog> createState() => _StingerBuildDialogState();
}

class _StingerBuildDialogState extends State<StingerBuildDialog> {
  late double gain = widget.initialGain.clamp(-6, 6);
  late final clips = [
    for (final station in widget.stations)
      for (final slot in stingerMaps(station['slots']))
        if (slot['assignment'] != null) {...slot, 'radio': station['radio']},
  ];
  late String selected = clips.isEmpty ? '' : '${clips.first['id']}';
  bool loading = false, playing = false;
  String? error;
  int generation = 0;
  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  void changed() {
    generation++;
    widget.stop();
    setState(() {
      playing = false;
      loading = false;
      error = null;
    });
  }

  Future<void> audition() async {
    if (playing) {
      changed();
      return;
    }
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final edit = stingerMap(
        clips.firstWhere((s) => s['id'] == selected)['assignment'],
      );
      final audio = await widget.preview({...edit, 'build_gain_db': gain});
      if (!mounted || current != generation) return;
      await widget.play(audio);
      if (mounted && current == generation) setState(() => playing = true);
    } on Object catch (e) {
      if (mounted && current == generation) {
        setState(() => error = '$e'.replaceFirst('FormatException: ', ''));
      }
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final radios = clips.map((s) => s['radio']).toSet();
    return TimingDialogFrame(
      title: '构建准备包',
      icon: 'volume',
      width: 560,
      busy: false,
      closeKey: const ValueKey('stinger-build-close'),
      description: '试听并调整台呼音量，确认后与歌曲一起构建。',
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              RmChip(
                label: '${radios.length} 个电台',
                variant: RmChipVariant.accent,
              ),
              RmChip(
                label: '${clips.length} 条替换台呼',
                variant: RmChipVariant.accent,
              ),
              RmChip(
                label: '编码质量 ${widget.quality}',
                variant: RmChipVariant.muted,
              ),
            ],
          ),
          if (widget.restoredRadios.isNotEmpty) ...[
            const SizedBox(height: 12),
            RmBanner(
              kind: RmBannerKind.info,
              title: '歌曲沿用原版：${widget.restoredRadios.join('、')}',
              body: '与游戏一致的歌曲文件不会加入准备包；只有确实需要恢复原版时才会打包。',
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '仅打包实际改动及必要配置。与游戏一致的歌曲 bank、RadioInfo 和语言文件会自动省略，其他电台的内容保持不变。',
            key: const ValueKey('stinger-build-file-scope'),
            style: RmText.sans(11.5, color: rm.fg3),
          ),
          const SizedBox(height: 14),
          DialogSettingsSection(
            title: '台呼统一增益',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)} dB',
                        style: RmText.mono(
                          22,
                          color: rm.accent.base,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    RmButton(
                      label: '恢复默认',
                      size: RmButtonSize.sm,
                      onPressed: clips.isEmpty
                          ? null
                          : () {
                              gain = 0;
                              changed();
                            },
                    ),
                  ],
                ),
                SizedBox(
                  height: 34,
                  child: RmSlider(
                    key: const ValueKey('stinger-build-gain'),
                    value: gain,
                    min: -6,
                    max: 6,
                    divisions: 24,
                    activeColor: rm.accent.base,
                    label: '${gain.toStringAsFixed(1)} dB',
                    onChanged: clips.isEmpty
                        ? null
                        : (v) {
                            gain = v;
                            changed();
                          },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final label in ['−6 dB', '0', '+6 dB'])
                      Text(label, style: RmText.mono(10.5, color: rm.fg3)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '统一叠加到替换台呼；原有台呼和歌曲保持原设置。',
                  style: RmText.sans(12, color: rm.fg3),
                ),
              ],
            ),
          ),
          if (clips.isNotEmpty) ...[
            const SizedBox(height: 12),
            DialogSettingsSection(
              title: '试听台呼',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: RmSelect<String>(
                          value: selected,
                          items: {
                            for (final s in clips)
                              '${s['id']}':
                                  'R${s['radio']} · 台呼 ${s['number']}',
                          },
                          onChanged: (v) {
                            selected = v;
                            changed();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      RmButton(
                        key: const ValueKey('stinger-build-audition'),
                        label: loading
                            ? '准备中'
                            : playing
                            ? '停止'
                            : '试听',
                        leading: RmIcon(playing ? 'stop' : 'play', size: 13),
                        onPressed: loading ? null : audition,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '试听与构建使用相同的裁剪和音量处理。',
                    style: RmText.sans(11.5, color: rm.fg3),
                  ),
                ],
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            RmBanner(kind: RmBannerKind.danger, title: '试听未完成', body: error!),
          ],
        ],
      ),
      actions: [
        RmButton(label: '返回编辑', onPressed: () => Navigator.pop(context)),
        RmButton(
          key: const ValueKey('stinger-build-confirm'),
          label: '构建准备包',
          leading: const RmIcon('music', size: 13),
          variant: RmButtonVariant.primary,
          onPressed: loading || error != null
              ? null
              : () => Navigator.pop(context, gain),
        ),
      ],
    );
  }
}
