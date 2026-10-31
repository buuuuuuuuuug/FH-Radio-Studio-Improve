import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_state.dart';

enum RadioHeightMode { manual, allStations, oneRow }

class LayoutOptions {
  const LayoutOptions({
    this.width = 0,
    this.radioHeight = 480,
    this.manualRefineWidth = 1080,
    this.radioColumns = 0,
    this.heightMode = RadioHeightMode.manual,
  });
  static const minColumnWidth = 205.0;
  static const gap = 12.0;
  final double width, radioHeight, manualRefineWidth;

  /// Zero fits the available width; 2–6 are explicit column counts.
  final int radioColumns;
  final RadioHeightMode heightMode;
  double pageWidth(double original) => width == 0
      ? original
      : width < 0
      ? double.infinity
      : width;
  static int maxColumnsFor(double available) =>
      ((available + gap) ~/ (minColumnWidth + gap)).clamp(1, 6);
  int columnsFor(double available) => radioColumns == 0
      ? maxColumnsFor(available)
      : radioColumns.clamp(1, maxColumnsFor(available));
  double canvasWidth(double available) => available;
  static double poolWidthFor(double width) => width >= 1120
      ? 280
      : width >= 780
      ? 260
      : (width * .4).clamp(160.0, 220.0);
  static double radioWidthFor(double width, {required bool withPool}) =>
      (width -
              (withPool && width >= minColumnWidth + gap + 160
                  ? poolWidthFor(width) + gap
                  : 0))
          .clamp(1.0, double.infinity);
  double heightFor(double viewport, int stations, int columns) {
    if (heightMode == RadioHeightMode.manual) return radioHeight;
    final rows = heightMode == RadioHeightMode.oneRow
        ? 1
        : math.max(1, (stations / columns).ceil());
    // Keep one song visible below the header; scroll when all stations cannot fit.
    return math.max(180.0, (viewport - gap * (rows - 1)) / rows);
  }

  LayoutOptions copyWith({
    double? width,
    double? radioHeight,
    double? manualRefineWidth,
    int? radioColumns,
    RadioHeightMode? heightMode,
  }) => LayoutOptions(
    width: width ?? this.width,
    radioHeight: radioHeight ?? this.radioHeight,
    manualRefineWidth: manualRefineWidth ?? this.manualRefineWidth,
    radioColumns: radioColumns ?? this.radioColumns,
    heightMode: heightMode ?? this.heightMode,
  );
}

class LayoutOptionsController extends StateNotifier<LayoutOptions> {
  LayoutOptionsController(
    this.prefs, {
    this.preferencePrefix = 'layout',
    this.defaultRadioHeight = 480,
  }) : super(
         LayoutOptions(
           width: prefs.getDouble('layout.width') ?? 0,
           manualRefineWidth:
               (prefs.getDouble('layout.manualRefineWidth') ?? 1080).clamp(
                 640,
                 10000,
               ),
           radioHeight:
               (prefs.getDouble('$preferencePrefix.radioHeight') ??
                       defaultRadioHeight)
                   .clamp(160, 1200),
           radioColumns: _columns(
             prefs.getInt('$preferencePrefix.radioColumns'),
           ),
           heightMode: RadioHeightMode.values.firstWhere(
             (mode) =>
                 mode.name == prefs.getString('$preferencePrefix.heightMode'),
             orElse: () => RadioHeightMode.manual,
           ),
         ),
       );
  final SharedPreferences prefs;
  final String preferencePrefix;
  final double defaultRadioHeight;
  Timer? _persistTimer;
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), _persist);
  }

  void _persist() {
    if (preferencePrefix == 'layout') {
      prefs.setDouble('layout.width', state.width);
      prefs.setDouble('layout.manualRefineWidth', state.manualRefineWidth);
    }
    prefs.setDouble('$preferencePrefix.radioHeight', state.radioHeight);
    prefs.setInt('$preferencePrefix.radioColumns', state.radioColumns);
    prefs.setString('$preferencePrefix.heightMode', state.heightMode.name);
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _persist();
    super.dispose();
  }

  static int _columns(int? value) =>
      value != null && value >= 2 && value <= 6 ? value : 0;
  void setWidth(double value) {
    if (!value.isFinite || state.width == value) return;
    state = state.copyWith(width: value);
    _schedulePersist();
  }

  void setManualRefineWidth(double value) {
    if (!value.isFinite) return;
    final width = value.clamp(640.0, 10000.0);
    state = state.copyWith(manualRefineWidth: width);
    _schedulePersist();
  }

  void setRadioHeight(double value) {
    if (!value.isFinite) return;
    final height = value.clamp(160.0, 1200.0);
    state = state.copyWith(
      radioHeight: height,
      heightMode: RadioHeightMode.manual,
    );
    _schedulePersist();
  }

  void setRadioColumns(int value) {
    if (state.radioColumns == _columns(value)) return;
    state = state.copyWith(radioColumns: _columns(value));
    _schedulePersist();
  }

  void setHeightMode(RadioHeightMode mode) {
    state = state.copyWith(heightMode: mode);
    _schedulePersist();
  }
}

final layoutOptionsProvider =
    StateNotifierProvider<LayoutOptionsController, LayoutOptions>(
      (ref) => LayoutOptionsController(ref.watch(sharedPreferencesProvider)),
    );

final stingerLayoutOptionsProvider =
    StateNotifierProvider<LayoutOptionsController, LayoutOptions>(
      (ref) => LayoutOptionsController(
        ref.watch(sharedPreferencesProvider),
        preferencePrefix: 'stinger.layout',
        defaultRadioHeight: 660,
      ),
    );
