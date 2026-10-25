import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Assignment shortcuts must not consume digits typed into a focused field.
bool assignmentKeyboardAvailable(BuildContext context, KeyEvent event) {
  if (event is! KeyDownEvent ||
      ModalRoute.of(context)?.isCurrent == false ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isMetaPressed) {
    return false;
  }
  final focusContext = FocusManager.instance.primaryFocus?.context;
  return focusContext?.widget is! EditableText &&
      focusContext?.findAncestorWidgetOfExactType<EditableText>() == null;
}

({String radio, String type})? assignmentDigitShortcut(
  KeyEvent event, {
  required bool splitTypes,
}) {
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const pads = [
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  var index = digits.indexOf(event.logicalKey);
  if (index < 0) index = pads.indexOf(event.logicalKey);
  if (index < 0) return null;
  return (
    radio: 'R${index + 1}',
    type: splitTypes && !HardwareKeyboard.instance.isControlPressed
        ? 'Event'
        : 'FreeRoam',
  );
}

String assignmentShortcutHint({required bool splitTypes, bool batch = false}) =>
    '${splitTypes ? '1–9 比赛 · Ctrl + 1–9 漫游' : '1–9 选择电台'}'
    ' · 支持小键盘${batch ? ' · Enter 分配' : ''} · Esc 取消';
