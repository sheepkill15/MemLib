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
  int? previousFocus;

  void rememberTarget() {
    if (!Platform.isWindows) return;
    previousWindow = GetForegroundWindow();
    previousFocus = null;
    final target = previousWindow;
    if (target == null || target == 0) return;
    final threadId = GetWindowThreadProcessId(target, nullptr);
    if (threadId == 0) return;
    final info = calloc<GUITHREADINFO>();
    try {
      info.ref.cbSize = sizeOf<GUITHREADINFO>();
      if (GetGUIThreadInfo(threadId, info) == 0) return;
      final focused = info.ref.hwndFocus;
      if (focused != 0 && (focused == target || IsChild(target, focused) != 0)) {
        previousFocus = focused;
      }
    } finally {
      calloc.free(info);
    }
  }

  void clearTarget() {
    previousWindow = null;
    previousFocus = null;
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
    if (IsWindow(target) == 0) return false;
    await windowManager.hide();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (SetForegroundWindow(target) == 0) return false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (GetForegroundWindow() != target) return false;
    final focus = previousFocus;
    if (focus != null && focus != 0 && IsWindow(focus) != 0) {
      final targetThread = GetWindowThreadProcessId(target, nullptr);
      final ownThread = GetCurrentThreadId();
      if (targetThread != 0 && targetThread != ownThread && AttachThreadInput(ownThread, targetThread, 1) != 0) {
        try {
          SetFocus(focus);
        } finally {
          AttachThreadInput(ownThread, targetThread, 0);
        }
      }
    }
    if (GetForegroundWindow() != target) return false;
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
