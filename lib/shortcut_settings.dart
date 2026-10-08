import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ShortcutSettings {
  static const _key = 'windows_picker_shortcut';

  static HotKey defaultShortcut() => HotKey(
    key: PhysicalKeyboardKey.keyV,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
  );

  /// Do not use HotKey.debugName for user-facing text: Flutter strips
  /// PhysicalKeyboardKey.debugName in release builds (it becomes null).
  static String displayLabel(HotKey hotKey) {
    const modifierLabels = <HotKeyModifier, String>{
      HotKeyModifier.control: 'Ctrl',
      HotKeyModifier.alt: 'Alt',
      HotKeyModifier.shift: 'Shift',
      HotKeyModifier.meta: 'Win',
      HotKeyModifier.capsLock: 'Caps Lock',
      HotKeyModifier.fn: 'Fn',
    };
    final selectedModifiers = hotKey.modifiers ?? const <HotKeyModifier>[];
    final key = hotKey.physicalKey;
    var keyLabel = key.keyLabel.trim();
    if (keyLabel.isEmpty || keyLabel == 'null' || keyLabel == 'Unknown') {
      keyLabel = 'Key 0x${key.usbHidUsage.toRadixString(16).toUpperCase()}';
    }
    return [
      for (final modifier in modifierLabels.keys)
        if (selectedModifiers.contains(modifier)) modifierLabels[modifier]!,
      keyLabel,
    ].join(' + ');
  }

  static bool isUsable(HotKey hotKey) {
    final modifiers = hotKey.modifiers ?? [];
    if (!modifiers.any(
      (modifier) =>
          modifier == HotKeyModifier.control ||
          modifier == HotKeyModifier.alt ||
          modifier == HotKeyModifier.meta,
    )) {
      return false;
    }
    return !HotKeyModifier.values.any(
      (modifier) => modifier.physicalKeys.contains(hotKey.physicalKey),
    );
  }

  static Future<HotKey> load() async {
    final value = (await SharedPreferences.getInstance()).getString(_key);
    if (value == null) return defaultShortcut();
    try {
      final hotKey = HotKey.fromJson(jsonDecode(value) as Map<String, dynamic>);
      return isUsable(hotKey) ? hotKey : defaultShortcut();
    } catch (_) {
      return defaultShortcut();
    }
  }

  static Future<void> save(HotKey hotKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(hotKey.toJson()));
  }
}
