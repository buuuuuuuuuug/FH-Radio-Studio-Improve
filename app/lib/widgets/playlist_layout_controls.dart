import 'rm_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/layout_options.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import 'rm_button.dart';

class PlaylistLayoutControls extends ConsumerWidget {
  const PlaylistLayoutControls({
    super.key,
    required this.availableRadioWidth,
    this.showHeight = true,
    this.topSpacing = 10,
    this.controllerProvider,
  });
  final double availableRadioWidth;
  final bool showHeight;
  final double topSpacing;
  final StateNotifierProvider<LayoutOptionsController, LayoutOptions>?
  controllerProvider;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = controllerProvider ?? layoutOptionsProvider;
    final options = ref.watch(provider);
    final ctl = ref.read(provider.notifier);
    final defaultHeight = ctl.defaultRadioHeight;
    final rm = context.rm;
    final maxColumns = LayoutOptions.maxColumnsFor(availableRadioWidth);
    final effective = options.columnsFor(availableRadioWidth);
    final columnStep = options.radioColumns == 0 || maxColumns == 1
        ? 0.0
        : effective - 1.0;
    Widget styledSlider(Widget child) => SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
      ),
      child: child,
    );
    Widget label(String text, double width) => SizedBox(
      width: width,
      height: 32,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text, maxLines: 1, style: RmText.sans(11.5, color: rm.fg2)),
      ),
    );
    final columns = Row(
      children: [
        label('电台列数', 60),
        label(
          options.radioColumns == 0 || maxColumns == 1
              ? '自动适应'
              : '$effective 列',
          54,
        ),
        Expanded(
          child: Tooltip(
            message: '当前宽度最多 $maxColumns 列；每列至少 205 px，列间距 12 px',
            child: SizedBox(
              height: 32,
              child: styledSlider(
                RmSlider(
                  key: const ValueKey('radio-columns-slider'),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  value: columnStep,
                  min: 0,
                  max: (maxColumns - 1).toDouble(),
                  divisions: maxColumns > 1 ? maxColumns - 1 : null,
                  label: columnStep == 0 ? '自动适应' : '$effective 列',
                  activeColor: rm.accent.base,
                  onChanged: maxColumns <= 1
                      ? null
                      : (v) => ctl.setRadioColumns(
                          v.round() == 0 ? 0 : v.round() + 1,
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    if (!showHeight) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 280, child: columns),
        ),
      );
    }
    final modes = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final mode in RadioHeightMode.values)
          RmButton(
            key: ValueKey('radio-height-${mode.name}'),
            size: RmButtonSize.sm,
            label: switch (mode) {
              RadioHeightMode.manual => '手动高度',
              RadioHeightMode.allStations => '全部电台',
              RadioHeightMode.oneRow => '一行电台',
            },
            tooltip: switch (mode) {
              RadioHeightMode.manual => '直接拖动高度滑块',
              RadioHeightMode.allStations => '随窗口和实际列数适应，展示所有电台',
              RadioHeightMode.oneRow => '随窗口适应，展示一行电台',
            },
            variant: options.heightMode == mode
                ? RmButtonVariant.primary
                : RmButtonVariant.defaultBtn,
            onPressed: () => ctl.setHeightMode(
              options.heightMode == mode && mode != RadioHeightMode.manual
                  ? RadioHeightMode.manual
                  : mode,
            ),
          ),
      ],
    );
    final heightSlider = Row(
      children: [
        label(
          options.heightMode == RadioHeightMode.manual
              ? '${options.radioHeight.round()} px'
              : '自动高度',
          64,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: 32,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: styledSlider(
                      RmSlider(
                        key: const ValueKey('radio-height-slider'),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        value: options.radioHeight,
                        min: 160,
                        max: 1200,
                        label: '${options.radioHeight.round()} px',
                        activeColor: rm.accent.base,
                        onChanged: options.heightMode == RadioHeightMode.manual
                            ? ctl.setRadioHeight
                            : null,
                      ),
                    ),
                  ),
                  Positioned(
                    left:
                        10 +
                        (c.maxWidth - 20) *
                            (defaultHeight - 160) /
                            (1200 - 160) -
                        2,
                    top: 11,
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('default-height-marker'),
                        width: 4,
                        height: 10,
                        decoration: BoxDecoration(
                          color: rm.accent.base,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        RmButton.icon(
          icon: const Icon(Icons.restart_alt, size: 14),
          tooltip: '恢复默认高度 · ${defaultHeight.round()} px',
          onPressed: () => ctl.setRadioHeight(defaultHeight),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(top: topSpacing),
      child: LayoutBuilder(
        builder: (context, c) {
          final heightControls = c.maxWidth >= 680
              ? Row(
                  children: [
                    label('电台高度', 60),
                    modes,
                    const SizedBox(width: 10),
                    Expanded(child: heightSlider),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('电台高度', style: RmText.sans(11.5, color: rm.fg2)),
                        modes,
                      ],
                    ),
                    heightSlider,
                  ],
                );
          return c.maxWidth >= 930
              ? Row(
                  children: [
                    SizedBox(width: 280, child: columns),
                    const SizedBox(width: 16),
                    Expanded(child: heightControls),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: c.maxWidth.clamp(0, 280),
                        child: columns,
                      ),
                    ),
                    const SizedBox(height: 4),
                    heightControls,
                  ],
                );
        },
      ),
    );
  }
}
