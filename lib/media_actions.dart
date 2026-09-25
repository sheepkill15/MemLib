import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

class MediaActions {
  static const _androidClipboard = MethodChannel('memlib/clipboard');
  int? previousWindow;

  void rememberTarget() {
    if (Platform.isWindows) previousWindow = GetForegroundWindow();
  }

  Future<void> copyFile(File file) async {
    if (Platform.isAndroid) {
      await _androidClipboard.invokeMethod<void>('copyFile', {'path': file.path});
    } else if (Platform.isWindows) {
      if (file.path.toLowerCase().endsWith('.png')) {
        await Pasteboard.writeImage(await file.readAsBytes());
      } else {
        final copied = await Pasteboard.writeFiles([file.path]);
        if (!copied) throw StateError('Could not put file on clipboard');
      }
    } else {
      throw UnsupportedError('Clipboard is unavailable on this platform');
    }
  }

  Future<void> copyBytes(Uint8List bytes, String extension) async {
    final cache = await getTemporaryDirectory();
    for (final entry in cache.listSync().whereType<File>()) {
      if (entry.uri.pathSegments.last.startsWith('memlib-share-') &&
          DateTime.now().difference(entry.lastModifiedSync()) > const Duration(hours: 1)) {
        try { await entry.delete(); } catch (_) { /* Clipboard may still use it. */ }
      }
    }
    final transient = File('${cache.path}${Platform.pathSeparator}memlib-share-${DateTime.now().microsecondsSinceEpoch}.$extension');
    await transient.writeAsBytes(bytes, flush: true);
    await copyFile(transient);
  }

  Future<bool> pasteIntoPreviousWindow() async {
    if (!Platform.isWindows || previousWindow == null || previousWindow == 0) return false;
    final target = previousWindow!;
    await windowManager.hide();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (SetForegroundWindow(target) == 0) return false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final inputs = calloc<INPUT>(4);
    try {
      for (var i = 0; i < 4; i++) {
        inputs[i].type = INPUT_KEYBOARD;
        inputs[i].ki.wVk = i == 0 || i == 3 ? VK_CONTROL : VK_V;
        inputs[i].ki.dwFlags = i >= 2 ? KEYEVENTF_KEYUP : 0;
      }
      return SendInput(4, inputs, sizeOf<INPUT>()) == 4;
    } finally {
      calloc.free(inputs);
    }
  }
}
