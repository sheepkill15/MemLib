import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:memlib/shortcut_settings.dart';

void main() {
  test('default shortcut has a human-readable, release-safe label', () {
    final label = ShortcutSettings.displayLabel(
      ShortcutSettings.defaultShortcut(),
    );
    expect(label, 'Ctrl + Alt + V');
    expect(label.toLowerCase(), isNot(contains('null')));
  });

  test('custom shortcuts display modifiers consistently', () {
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.f12,
      modifiers: [
        HotKeyModifier.meta,
        HotKeyModifier.shift,
        HotKeyModifier.control,
      ],
    );
    expect(ShortcutSettings.displayLabel(hotKey), 'Ctrl + Shift + Win + F12');
  });

  test('deserialized user shortcut preserves its visible label', () {
    final shortcut = HotKey(
      key: PhysicalKeyboardKey.keyK,
      modifiers: [HotKeyModifier.alt, HotKeyModifier.control],
    );
    final restored = HotKey.fromJson(
      jsonDecode(jsonEncode(shortcut.toJson())) as Map<String, dynamic>,
    );
    expect(ShortcutSettings.displayLabel(restored), 'Ctrl + Alt + K');
  });
}
