import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_state.dart';

enum EditorAction {
  play,
  confirm,
  save,
  undo,
  redo,
  beatBack,
  beatForward,
  tenBack,
  tenForward,
  oneBack,
  oneForward,
  previous,
  next,
  suggestionPrevious,
  suggestionNext,
  restoreSaved,
  assign,
  manualTd,
  manualPd,
  manualTl,
  manualPl,
  markPlayback,
  toggleSnap,
  freePlace,
  loopBeatBack,
  loopBeatForward,
  loopTenBack,
  loopTenForward,
  loopOneBack,
  loopOneForward,
}

class EditorChord {
  const EditorChord(
    this.key, {
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.extraKey,
  });
  final LogicalKeyboardKey key;
  final bool ctrl, shift, alt, meta;
  final LogicalKeyboardKey? extraKey;
  String get token =>
      '${modifierKey(key) ? 'modifiers' : shortcutKey(key).keyId}:$ctrl:$shift:$alt:$meta:${extraKey == null ? null : shortcutKey(extraKey!).keyId}';
  EditorChord withAlt() => EditorChord(
    key,
    ctrl: ctrl,
    shift: shift,
    alt: true,
    meta: meta,
    extraKey: extraKey,
  );
  bool matches(
    KeyEvent event, {
    required bool ctrl,
    required bool shift,
    required bool alt,
    bool meta = false,
    Set<LogicalKeyboardKey>? pressedKeys,
  }) =>
      (shortcutKey(event.logicalKey) == shortcutKey(key) ||
          modifierKey(key) && modifierKey(event.logicalKey)) &&
      this.ctrl == ctrl &&
      this.shift == shift &&
      this.alt == alt &&
      this.meta == meta &&
      (extraKey == null ||
          (pressedKeys ?? HardwareKeyboard.instance.logicalKeysPressed).any(
            (pressed) => shortcutKey(pressed) == shortcutKey(extraKey!),
          ));
  String get label => [
    if (ctrl) 'Ctrl',
    if (meta) 'Win',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (extraKey != null) EditorChord(extraKey!).label,
    if (!modifierKey(key))
      switch (key) {
        LogicalKeyboardKey.arrowLeft => '←',
        LogicalKeyboardKey.arrowRight => '→',
        LogicalKeyboardKey.arrowUp => '↑',
        LogicalKeyboardKey.arrowDown => '↓',
        LogicalKeyboardKey.space => 'Space',
        LogicalKeyboardKey.tab => 'Tab',
        LogicalKeyboardKey.enter => 'Enter',
        LogicalKeyboardKey.pageUp => 'PageUp',
        LogicalKeyboardKey.pageDown => 'PageDown',
        LogicalKeyboardKey.home => 'Home',
        _ => key.keyLabel.toUpperCase(),
      },
  ].join(' + ');
  Map<String, dynamic> toJson() => {
    'key': key.keyId,
    'ctrl': ctrl,
    'shift': shift,
    'alt': alt,
    'meta': meta,
    if (extraKey != null) 'extraKey': extraKey!.keyId,
  };
  static EditorChord? fromJson(Object? raw) {
    if (raw is! Map || raw['key'] is! int) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(raw['key']);
    if (key == null || key == LogicalKeyboardKey.escape) {
      return null;
    }
    return EditorChord(
      key,
      ctrl: raw['ctrl'] == true,
      shift: raw['shift'] == true,
      alt: raw['alt'] == true,
      meta: raw['meta'] == true,
      extraKey: raw['extraKey'] is int
          ? LogicalKeyboardKey.findKeyByKeyId(raw['extraKey'])
          : null,
    );
  }
}

// Number-row and numeric-keypad digits represent the same shortcut.
LogicalKeyboardKey shortcutKey(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.numpad0 => LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.numpad1 => LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.numpad2 => LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.numpad3 => LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.numpad4 => LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.numpad5 => LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.numpad6 => LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.numpad7 => LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.numpad8 => LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.numpad9 => LogicalKeyboardKey.digit9,
  _ => key,
};

bool modifierKey(LogicalKeyboardKey key) => {
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
}.contains(key);
const nudgeActions = {
  EditorAction.beatBack,
  EditorAction.beatForward,
  EditorAction.tenBack,
  EditorAction.tenForward,
  EditorAction.oneBack,
  EditorAction.oneForward,
};
const loopNudgeActions = {
  EditorAction.loopBeatBack,
  EditorAction.loopBeatForward,
  EditorAction.loopTenBack,
  EditorAction.loopTenForward,
  EditorAction.loopOneBack,
  EditorAction.loopOneForward,
};
EditorAction baseNudgeAction(EditorAction action) => switch (action) {
  EditorAction.loopBeatBack => EditorAction.beatBack,
  EditorAction.loopBeatForward => EditorAction.beatForward,
  EditorAction.loopTenBack => EditorAction.tenBack,
  EditorAction.loopTenForward => EditorAction.tenForward,
  EditorAction.loopOneBack => EditorAction.oneBack,
  EditorAction.loopOneForward => EditorAction.oneForward,
  _ => action,
};
String editorActionLabel(EditorAction a) => switch (a) {
  EditorAction.play => '播放 / 暂停',
  EditorAction.confirm => '确认当前选点',
  EditorAction.save => '保存歌曲配置',
  EditorAction.undo => '撤销',
  EditorAction.redo => '重做',
  EditorAction.beatBack => '后退 1 拍',
  EditorAction.beatForward => '前进 1 拍',
  EditorAction.tenBack => '减少 10ms',
  EditorAction.tenForward => '增加 10ms',
  EditorAction.oneBack => '减少 1ms',
  EditorAction.oneForward => '增加 1ms',
  EditorAction.previous => '上一首',
  EditorAction.next => '下一首',
  EditorAction.suggestionPrevious => '精修：上一条建议',
  EditorAction.suggestionNext => '精修：下一条建议',
  EditorAction.restoreSaved => '精修：回到已保存配置',
  EditorAction.assign => '分配至电台',
  EditorAction.manualTd => '人工选点：TD',
  EditorAction.manualPd => '人工选点：PD',
  EditorAction.manualTl => '人工选点：TL',
  EditorAction.manualPl => '人工选点：PL',
  EditorAction.markPlayback => '精修：取当前播放位置',
  EditorAction.toggleSnap => '精修：切换磁吸 / 自由放置',
  EditorAction.freePlace => '精修：按住自由放置',
  EditorAction.loopBeatBack => '循环两端：后退 1 拍',
  EditorAction.loopBeatForward => '循环两端：前进 1 拍',
  EditorAction.loopTenBack => '循环两端：减少 10ms',
  EditorAction.loopTenForward => '循环两端：增加 10ms',
  EditorAction.loopOneBack => '循环两端：减少 1ms',
  EditorAction.loopOneForward => '循环两端：增加 1ms',
};
Map<EditorAction, EditorChord> defaultEditorShortcuts() {
  final result = <EditorAction, EditorChord>{
    EditorAction.play: const EditorChord(LogicalKeyboardKey.space),
    EditorAction.confirm: const EditorChord(LogicalKeyboardKey.enter),
    EditorAction.save: const EditorChord(LogicalKeyboardKey.keyS, ctrl: true),
    EditorAction.undo: const EditorChord(LogicalKeyboardKey.keyZ, ctrl: true),
    EditorAction.redo: const EditorChord(LogicalKeyboardKey.keyY, ctrl: true),
    EditorAction.beatBack: const EditorChord(LogicalKeyboardKey.arrowLeft),
    EditorAction.beatForward: const EditorChord(LogicalKeyboardKey.arrowRight),
    EditorAction.tenBack: const EditorChord(
      LogicalKeyboardKey.arrowLeft,
      shift: true,
    ),
    EditorAction.tenForward: const EditorChord(
      LogicalKeyboardKey.arrowRight,
      shift: true,
    ),
    EditorAction.oneBack: const EditorChord(
      LogicalKeyboardKey.arrowLeft,
      ctrl: true,
    ),
    EditorAction.oneForward: const EditorChord(
      LogicalKeyboardKey.arrowRight,
      ctrl: true,
    ),
    EditorAction.previous: const EditorChord(
      LogicalKeyboardKey.arrowUp,
      shift: true,
    ),
    EditorAction.next: const EditorChord(
      LogicalKeyboardKey.arrowDown,
      shift: true,
    ),
    EditorAction.suggestionPrevious: const EditorChord(
      LogicalKeyboardKey.arrowUp,
      ctrl: true,
    ),
    EditorAction.suggestionNext: const EditorChord(
      LogicalKeyboardKey.arrowDown,
      ctrl: true,
    ),
    EditorAction.assign: const EditorChord(LogicalKeyboardKey.keyD, ctrl: true),
    EditorAction.manualTd: const EditorChord(
      LogicalKeyboardKey.digit1,
      ctrl: true,
    ),
    EditorAction.manualPd: const EditorChord(
      LogicalKeyboardKey.digit2,
      ctrl: true,
    ),
    EditorAction.manualTl: const EditorChord(
      LogicalKeyboardKey.digit3,
      ctrl: true,
    ),
    EditorAction.manualPl: const EditorChord(
      LogicalKeyboardKey.digit4,
      ctrl: true,
    ),
    EditorAction.markPlayback: const EditorChord(LogicalKeyboardKey.tab),
    EditorAction.freePlace: const EditorChord(LogicalKeyboardKey.keyZ),
    EditorAction.toggleSnap: const EditorChord(
      LogicalKeyboardKey.keyZ,
      shift: true,
    ),
    EditorAction.restoreSaved: const EditorChord(
      LogicalKeyboardKey.keyH,
      ctrl: true,
    ),
  };
  for (final action in loopNudgeActions) {
    result[action] = withLoopModifier(result[baseNudgeAction(action)]!, 'Alt');
  }
  return result;
}

const loopModifierNames = ['Alt', 'Control', 'Shift', 'Meta'];
String loopModifierForKey(LogicalKeyboardKey key) => switch (key) {
  LogicalKeyboardKey.altLeft || LogicalKeyboardKey.altRight => 'Alt',
  LogicalKeyboardKey.controlLeft ||
  LogicalKeyboardKey.controlRight => 'Control',
  LogicalKeyboardKey.shiftLeft || LogicalKeyboardKey.shiftRight => 'Shift',
  LogicalKeyboardKey.metaLeft || LogicalKeyboardKey.metaRight => 'Meta',
  _ => 'Key:${key.keyId}',
};
LogicalKeyboardKey? loopExtraKey(String value) {
  if (!value.startsWith('Key:')) return null;
  final id = int.tryParse(value.substring(4));
  return id == null ? null : LogicalKeyboardKey.findKeyByKeyId(id);
}

bool validLoopModifier(String value) {
  final key = loopExtraKey(value);
  return loopModifierNames.contains(value) ||
      (key != null && key != LogicalKeyboardKey.escape && !modifierKey(key));
}

String loopModifierLabel(String value) => switch (value) {
  'Control' => 'Ctrl',
  'Meta' => 'Win',
  _ =>
    loopExtraKey(value) == null
        ? value
        : EditorChord(loopExtraKey(value)!).label,
};
String loopCombinationLabel(Map<EditorAction, EditorChord> keys) {
  final a = keys[EditorAction.loopBeatBack]!, b = keys[EditorAction.beatBack]!;
  if (a.extraKey != null) return EditorChord(a.extraKey!).label;
  if (a.alt != b.alt) return 'Alt';
  if (a.ctrl != b.ctrl) return 'Ctrl';
  if (a.shift != b.shift) return 'Shift';
  if (a.meta != b.meta) return 'Win';
  return 'Alt';
}

String readLoopModifier(SharedPreferences prefs) {
  final value = prefs.getString('editor.loopModifier') ?? 'Alt';
  return validLoopModifier(value) ? value : 'Alt';
}

EditorChord withLoopModifier(EditorChord base, String modifier) => EditorChord(
  base.key,
  ctrl: modifier == 'Control' || base.ctrl,
  shift: modifier == 'Shift' || base.shift,
  alt: modifier == 'Alt' || base.alt,
  meta: modifier == 'Meta' || base.meta,
  extraKey: loopExtraKey(modifier),
);
final editorActionOrder = [
  ...EditorAction.values.where(
    (a) =>
        !loopNudgeActions.contains(a) &&
        a != EditorAction.previous &&
        a != EditorAction.next,
  ),
  EditorAction.previous,
  EditorAction.next,
];
String? shortcutConflict(Map<EditorAction, EditorChord> bindings) {
  final used = <String, String>{};
  for (final e in bindings.entries) {
    final extra = e.value.extraKey;
    if (extra == null) continue;
    if (extra == e.value.key ||
        extra == LogicalKeyboardKey.escape ||
        modifierKey(extra)) {
      return '两端同移组合键不能与微调键相同；Esc 保留用于返回。';
    }
    for (final action in bindings.entries) {
      if (!loopNudgeActions.contains(action.key) && action.value.key == extra) {
        return '两端同移组合键与“${editorActionLabel(action.key)}”使用同一按键，存在冲突。';
      }
    }
  }
  for (final e in bindings.entries) {
    final modifierOnly = modifierKey(e.value.key);
    final modifierCount = [
      e.value.ctrl,
      e.value.alt,
      e.value.shift,
      e.value.meta,
    ].where((value) => value).length;
    if (e.value.key == LogicalKeyboardKey.escape ||
        modifierOnly &&
            (e.key != EditorAction.toggleSnap || modifierCount < 2)) {
      return 'Esc 保留用于返回；不能只使用修饰键。';
    }
    final chord = e.value;
    final previous = used[chord.token];
    if (previous != null) return '${chord.label} 与“$previous”冲突。';
    used[chord.token] = editorActionLabel(e.key);
  }
  return null;
}

class EditorShortcutController
    extends StateNotifier<Map<EditorAction, EditorChord>> {
  EditorShortcutController(this.prefs) : super(defaultEditorShortcuts()) {
    try {
      final raw = jsonDecode(prefs.getString('editor.shortcuts.v1') ?? '{}');
      if (raw is Map) {
        final loaded = {...state};
        for (final a in EditorAction.values) {
          final chord = EditorChord.fromJson(raw[a.name]);
          if (chord != null) {
            final oldNavigationDefault =
                (prefs.getInt('editor.shortcuts.version') ?? 1) < 2 &&
                (a == EditorAction.previous || a == EditorAction.next) &&
                chord.key ==
                    (a == EditorAction.previous
                        ? LogicalKeyboardKey.arrowUp
                        : LogicalKeyboardKey.arrowDown) &&
                chord.alt &&
                chord.shift &&
                !chord.ctrl;
            final oldRestoreDefault =
                (prefs.getInt('editor.shortcuts.version') ?? 1) < 3 &&
                a == EditorAction.restoreSaved &&
                chord.key == LogicalKeyboardKey.home &&
                chord.ctrl &&
                !chord.shift &&
                !chord.alt;
            final previousDefault = switch (a) {
              EditorAction.previous => const EditorChord(
                LogicalKeyboardKey.arrowUp,
                ctrl: true,
                shift: true,
              ),
              EditorAction.next => const EditorChord(
                LogicalKeyboardKey.arrowDown,
                ctrl: true,
                shift: true,
              ),
              EditorAction.manualTd => const EditorChord(
                LogicalKeyboardKey.digit1,
                ctrl: true,
                shift: true,
              ),
              EditorAction.manualPd => const EditorChord(
                LogicalKeyboardKey.digit2,
                ctrl: true,
                shift: true,
              ),
              EditorAction.manualTl => const EditorChord(
                LogicalKeyboardKey.digit3,
                ctrl: true,
                shift: true,
              ),
              EditorAction.manualPl => const EditorChord(
                LogicalKeyboardKey.digit4,
                ctrl: true,
                shift: true,
              ),
              EditorAction.markPlayback => const EditorChord(
                LogicalKeyboardKey.keyM,
                ctrl: true,
              ),
              EditorAction.toggleSnap => const EditorChord(
                LogicalKeyboardKey.altLeft,
                alt: true,
                shift: true,
              ),
              _ => null,
            };
            final oldEditorDefault =
                (prefs.getInt('editor.shortcuts.version') ?? 1) < 8 &&
                chord.token == previousDefault?.token;
            final previousGroupKey = switch (a) {
              EditorAction.manualTd => LogicalKeyboardKey.digit1,
              EditorAction.manualPd => LogicalKeyboardKey.digit2,
              EditorAction.manualTl => LogicalKeyboardKey.digit3,
              EditorAction.manualPl => LogicalKeyboardKey.digit4,
              _ => null,
            };
            final oldGroupDefault =
                (prefs.getInt('editor.shortcuts.version') ?? 1) < 9 &&
                previousGroupKey != null &&
                chord.token == EditorChord(previousGroupKey, shift: true).token;
            final oldRedoDefault =
                a == EditorAction.redo &&
                chord.token ==
                    const EditorChord(
                      LogicalKeyboardKey.keyZ,
                      ctrl: true,
                      shift: true,
                    ).token;
            if (!oldRedoDefault &&
                !oldNavigationDefault &&
                !oldRestoreDefault &&
                !oldEditorDefault &&
                !oldGroupDefault) {
              loaded[a] = chord;
            }
          }
        }
        final modifier = readLoopModifier(prefs);
        for (final action in loopNudgeActions) {
          loaded[action] = withLoopModifier(
            loaded[baseNudgeAction(action)]!,
            modifier,
          );
        }
        if (shortcutConflict(loaded) == null) state = Map.unmodifiable(loaded);
      }
    } on Object {
      /* Invalid old preferences safely fall back to defaults. */
    }
  }
  final SharedPreferences prefs;
  void setLoopModifier(String modifier) => save(state, loopModifier: modifier);

  void save(Map<EditorAction, EditorChord> value, {String? loopModifier}) {
    final modifier = loopModifier ?? readLoopModifier(prefs);
    if (!validLoopModifier(modifier)) {
      throw const FormatException('请选择有效的组合键；Esc 保留用于返回。');
    }
    value = {
      ...value,
      for (final action in loopNudgeActions)
        action: withLoopModifier(value[baseNudgeAction(action)]!, modifier),
    };
    final problem = shortcutConflict(value);
    if (problem != null) throw FormatException(problem);
    prefs.setString('editor.loopModifier', modifier);
    state = Map.unmodifiable(value);
    prefs.setInt('editor.shortcuts.version', 10);
    prefs.setString(
      'editor.shortcuts.v1',
      jsonEncode({for (final e in value.entries) e.key.name: e.value.toJson()}),
    );
  }
}

final editorShortcutsProvider =
    StateNotifierProvider<
      EditorShortcutController,
      Map<EditorAction, EditorChord>
    >((ref) => EditorShortcutController(ref.watch(sharedPreferencesProvider)));
