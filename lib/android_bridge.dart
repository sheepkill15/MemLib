import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'giphy_service.dart';
import 'klipy_service.dart';
import 'library_store.dart';

/// Native Android keyboard and share-sheet entry points. No-op off Android.
class AndroidBridge {
  static const _channel = MethodChannel('memlib/android');
  static final _sharedImages = StreamController<void>.broadcast();

  static Stream<void> get sharedImagesReady => _sharedImages.stream;

  static Future<void> initialize(LibraryStore store) async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedImagesReady') _sharedImages.add(null);
    });
    await setLibraryRoot(store);
  }

  static Future<void> setLibraryRoot(LibraryStore store) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('setLibraryRoot', {
      'path': store.root.path,
      'giphyKey': KlipyService.androidKey,
      'allowGiphySaves': GiphyService.librarySavesEnabled,
    });
  }

  static Future<List<String>> drainSharedImages() async {
    if (!Platform.isAndroid) return [];
    return await _channel.invokeListMethod<String>('drainSharedImages') ?? [];
  }

  static Future<void> ackSharedImages(List<String> paths) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('ackSharedImages', {'paths': paths});
  }

  static Future<List<String>> drainUsedIds() async {
    if (!Platform.isAndroid) return [];
    return await _channel.invokeListMethod<String>('drainUsedIds') ?? [];
  }

  static Future<List<Map<String, dynamic>>> drainGiphySaves() async {
    if (!Platform.isAndroid) return [];
    final values =
        await _channel.invokeListMethod<dynamic>('drainGiphySaves') ?? [];
    return values
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
  }

  static Future<void> ackGiphySave(String path) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('ackGiphySave', {'path': path});
  }

  static Future<void> openKeyboardSettings() =>
      _channel.invokeMethod<void>('openKeyboardSettings');
  static Future<void> showKeyboardPicker() =>
      _channel.invokeMethod<void>('showKeyboardPicker');
  static Future<void> importClipboardImage() =>
      _channel.invokeMethod<void>('importClipboardImage');
  static Future<void> shareFile(File file) =>
      _channel.invokeMethod<void>('shareFile', {'path': file.path});
  static Future<bool> installApk(File file) async =>
      await _channel.invokeMethod<bool>('installApk', {'path': file.path}) ??
      false;
}
