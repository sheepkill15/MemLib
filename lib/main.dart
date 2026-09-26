import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import 'giphy_service.dart';
import 'giphy_library.dart';
import 'android_bridge.dart';
import 'account_dialog.dart';
import 'cloud_controller.dart';
import 'library_store.dart';
import 'media_actions.dart';
import 'picker_navigation.dart';
import 'shortcut_settings.dart';
import 'windows_tray.dart';

const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: String.fromEnvironment('NEXT_PUBLIC_SUPABASE_URL'),
);
const supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
  defaultValue: String.fromEnvironment('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY'),
);

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabasePublishableKey,
    );
  }
  if (Platform.isWindows) {
    launchAtStartup.setup(
      appName: 'Memlib',
      appPath: '"${Platform.resolvedExecutable}"',
      args: ['--background'],
    );
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1050, 720),
        minimumSize: Size(600, 500),
        title: 'Memlib',
      ),
      () async {
        if (args.contains('--background')) {
          await windowManager.hide();
        } else {
          await windowManager.show();
        }
      },
    );
  }
  final store = LibraryStore();
  await store.load();
  final cloud = CloudController(
    store,
    supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty
        ? Supabase.instance.client
        : null,
  );
  await cloud.start();
  await AndroidBridge.initialize(store);
  final shortcut = Platform.isWindows ? await ShortcutSettings.load() : null;
  runApp(MemlibApp(store: store, cloud: cloud, initialShortcut: shortcut));
}

class MemlibApp extends StatelessWidget {
  const MemlibApp({
    super.key,
    required this.store,
    this.enableTray = true,
    this.initialShortcut,
    this.cloud,
    this.giphyService,
  });
  final LibraryStore store;
  final bool enableTray;
  final HotKey? initialShortcut;
  final CloudController? cloud;
  final GiphyService? giphyService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Memlib',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C5CDE),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF121019),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1B1724),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF24202E),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF211C2B),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    home: LibraryScreen(
      store: store,
      cloud: cloud,
      enableTray: enableTray,
      initialShortcut: initialShortcut,
      giphyService: giphyService,
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.store,
    this.enableTray = true,
    this.initialShortcut,
    this.cloud,
    this.giphyService,
  });
  final LibraryStore store;
  final bool enableTray;
  final HotKey? initialShortcut;
  final CloudController? cloud;
  final GiphyService? giphyService;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryDrag {
  const _LibraryDrag.item(this.id) : folder = false;
  const _LibraryDrag.folder(this.id) : folder = true;
  final String id;
  final bool folder;
}

class _LibraryScreenState extends State<LibraryScreen>
    with WindowListener, WidgetsBindingObserver {
  final actions = MediaActions();
  late final giphy = widget.giphyService ?? GiphyService();
  late final giphyLibrary = GiphyLibrary(widget.store, giphy.fetchForShare);
  final savingGiphy = <String>{};
  final searchController = TextEditingController();
  final giphyController = TextEditingController();
  final searchFocus = FocusNode();
  final giphyFocus = FocusNode();
  final pickerScroll = ScrollController();
  final giphyPickerScroll = ScrollController();
  final libraryGridScroll = ScrollController();
  final libraryGridKey = GlobalKey();
  final selectedItemIds = <String>{};
  final selectedTagFilters = <String>{};
  String? selectionAnchorId;
  bool mobileSelecting = false;
  double pickerGridWidth = 620;
  double giphyPickerGridWidth = 620;
  String? selectedFolder;
  final expandedFolders = <String>{};
  bool favoritesOnly = false;
  bool picker = false;
  bool giphyTab = false;
  bool stickerSearch = false;
  bool busy = false;
  bool giphyHasMore = false;
  bool giphyNavigating = false;
  int giphyOffset = 0;
  int giphyRequest = 0;
  String giphyQuery = '';
  bool windowTransition = false;
  bool pasting = false;
  bool draggingFiles = false;
  bool startupEnabled = false;
  int selectedIndex = 0;
  String? error;
  List<GiphyResult> results = [];
  final seenGiphy = <String>{};
  String? shownAccountId;
  late HotKey hotkey;
  WindowsTray? windowsTray;
  StreamSubscription<void>? sharedImagesSubscription;
  bool drainingAndroid = false;
  bool drainAndroidAgain = false;

  @override
  void initState() {
    super.initState();
    shownAccountId = widget.store.accountId;
    widget.store.addListener(_refresh);
    widget.cloud?.addListener(_refresh);
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      sharedImagesSubscription = AndroidBridge.sharedImagesReady.listen(
        (_) => unawaited(_drainAndroidPending()),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_drainAndroidPending());
      });
    }
    if (Platform.isWindows) {
      if (widget.enableTray) unawaited(_loadStartupSetting());
      windowManager.addListener(this);
      HardwareKeyboard.instance.addHandler(_handlePickerKey);
      hotkey = widget.initialShortcut ?? ShortcutSettings.defaultShortcut();
      hotKeyManager
          .register(
            hotkey,
            keyDownHandler: (_) => _togglePicker(fromShortcut: true),
          )
          .catchError((Object e) {
            if (mounted) {
              setState(() => error = 'Global shortcut unavailable: $e');
            }
          });
      if (widget.enableTray) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          try {
            windowsTray = WindowsTray();
            final ready = windowsTray!.initialize(
              openLibrary: () {
                if (mounted) unawaited(_openLibrary());
              },
              openPicker: () {
                if (mounted && !picker) unawaited(_togglePicker());
              },
              exitApp: () {
                if (mounted) unawaited(windowManager.close());
              },
              shortcutLabel: hotkey.debugName,
            );
            if (!ready) {
              windowsTray = null;
              debugPrint('Tray icon could not be shown');
            }
          } catch (e) {
            debugPrint('Tray initialization failed: $e');
          }
        });
      }
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
      sharedImagesSubscription?.cancel();
    }
    if (Platform.isWindows) {
      hotKeyManager.unregister(hotkey);
      windowsTray?.dispose();
      HardwareKeyboard.instance.removeHandler(_handlePickerKey);
      windowManager.removeListener(this);
    }
    widget.store.removeListener(_refresh);
    widget.cloud?.removeListener(_refresh);
    searchController.dispose();
    giphyController.dispose();
    searchFocus.dispose();
    giphyFocus.dispose();
    pickerScroll.dispose();
    giphyPickerScroll.dispose();
    libraryGridScroll.dispose();
    giphy.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      final activeIds = widget.store.items.map((item) => item.id).toSet();
      selectedItemIds.removeWhere((id) => !activeIds.contains(id));
      if (shownAccountId != widget.store.accountId) {
        shownAccountId = widget.store.accountId;
        selectedItemIds.clear();
        selectionAnchorId = null;
        if (Platform.isAndroid) {
          unawaited(AndroidBridge.setLibraryRoot(widget.store));
        }
        selectedFolder = null;
        favoritesOnly = false;
        selectedIndex = 0;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid && state == AppLifecycleState.resumed) {
      unawaited(_drainAndroidPending());
    }
  }

  Future<void> _drainAndroidPending() async {
    if (!Platform.isAndroid) return;
    if (drainingAndroid) {
      drainAndroidAgain = true;
      return;
    }
    drainingAndroid = true;
    try {
      final used = await AndroidBridge.drainUsedIds();
      for (final id in used) {
        final item = widget.store.items
            .where((item) => item.id == id)
            .firstOrNull;
        if (item != null) await widget.store.markUsed(item);
      }
      for (final pending in await AndroidBridge.drainGiphySaves()) {
        final file = File(pending['path'] as String);
        try {
          final result = GiphyResult(
            id: pending['id'] as String,
            title: pending['name'] as String,
            previewUrl: '',
            gifUrl: '',
            pageUrl: pending['sourcePage'] as String,
          );
          final existing = giphyLibrary.savedItem(result);
          if (pending['toggle'] == true && existing != null) {
            await giphyLibrary.setFavorite(result, pending['favorite'] == true);
          } else {
            final bytes = await file.readAsBytes();
            if (pending['toggle'] == true) {
              await giphyLibrary.setFavorite(
                result,
                pending['favorite'] == true,
                downloadedBytes: bytes,
              );
            } else {
              await giphyLibrary.save(result, downloadedBytes: bytes);
            }
          }
          await AndroidBridge.ackGiphySave(file.path);
          if (await file.exists()) await file.delete();
        } catch (e) {
          if (mounted) {
            _showError('Could not save a GIPHY result from the keyboard: $e');
          }
        }
      }
      while (mounted) {
        final paths = await AndroidBridge.drainSharedImages();
        if (paths.isEmpty) break;
        final imported = await _importPaths(paths);
        if (!imported) break;
        await AndroidBridge.ackSharedImages(paths);
        for (final path in paths) {
          final file = File(path);
          if (await file.exists()) await file.delete();
          final parent = file.parent;
          if (await parent.exists() && await parent.list().isEmpty) {
            await parent.delete();
          }
        }
      }
    } catch (e) {
      if (mounted) _showError('Could not import shared images: $e');
    } finally {
      drainingAndroid = false;
      if (drainAndroidAgain && mounted) {
        drainAndroidAgain = false;
        unawaited(_drainAndroidPending());
      }
    }
  }

  Future<void> _loadStartupSetting() async {
    try {
      final enabled = await launchAtStartup.isEnabled();
      if (mounted) setState(() => startupEnabled = enabled);
    } catch (e) {
      debugPrint('Could not read launch at sign-in setting: $e');
    }
  }

  Future<void> _toggleStartup() async {
    try {
      final enabled = startupEnabled
          ? await launchAtStartup.disable()
          : await launchAtStartup.enable();
      if (!enabled) throw StateError('Windows did not accept the change');
      await _loadStartupSetting();
      _showError(
        startupEnabled
            ? 'Memlib will start in the tray when you sign in.'
            : 'Launch at sign-in is off.',
      );
    } catch (e) {
      _showError('Could not change launch at sign-in: $e');
    }
  }

  @override
  void onWindowBlur() {
    if (picker && !windowTransition && !pasting) unawaited(_dismissPicker());
  }

  bool _handlePickerKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!picker &&
        Platform.isWindows &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        ModalRoute.of(context)?.isCurrent == true &&
        IsClipboardFormatAvailable(CF_HDROP) != 0) {
      unawaited(_importClipboardFiles());
      return true;
    }
    if (!picker || windowTransition || pasting || busy) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_dismissPicker());
      return true;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => PickerDirection.left,
      LogicalKeyboardKey.arrowRight => PickerDirection.right,
      LogicalKeyboardKey.arrowUp => PickerDirection.up,
      LogicalKeyboardKey.arrowDown => PickerDirection.down,
      _ => null,
    };
    if (direction != null) {
      if (giphyTab) giphyNavigating = true;
      _selectPickerIndex(
        movePickerSelection(
          selectedIndex,
          giphyTab ? results.length : visibleItems.length,
          giphyTab ? _giphyPickerColumns : 4,
          direction,
        ),
      );
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (giphyTab) {
        if (!giphyNavigating || results.isEmpty) {
          unawaited(_searchGiphy());
        } else if (results.isNotEmpty) {
          unawaited(
            _useGiphy(results[selectedIndex.clamp(0, results.length - 1)]),
          );
        }
      } else {
        final items = visibleItems;
        if (items.isNotEmpty) {
          unawaited(_useItem(items[selectedIndex.clamp(0, items.length - 1)]));
        }
      }
      return true;
    }
    return false;
  }

  void _selectPickerIndex(int index) {
    setState(() => selectedIndex = index);
    final itemsLength = giphyTab ? results.length : visibleItems.length;
    if (index < 0 || index >= itemsLength) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !picker || selectedIndex != index) return;
      _scrollPickerSelectionIntoView(index);
    });
  }

  int get _giphyPickerColumns =>
      ((giphyPickerGridWidth - 28) / (145 + 10)).ceil().clamp(1, 100);

  void _scrollPickerSelectionIntoView(int index) {
    final controller = giphyTab ? giphyPickerScroll : pickerScroll;
    if (!controller.hasClients) return;
    final columns = giphyTab ? _giphyPickerColumns : 4;
    final width = giphyTab ? giphyPickerGridWidth : pickerGridWidth;
    final tileWidth = (width - 28 - (columns - 1) * 10) / columns;
    final tileHeight = giphyTab ? tileWidth / 0.94 : tileWidth;
    final top = (giphyTab ? 4.0 : 0.0) + (index ~/ columns) * (tileHeight + 10);
    final bottom = top + tileHeight;
    final position = controller.position;
    const margin = 8.0;
    double? destination;
    if (top < position.pixels + margin) {
      destination = top - margin;
    } else if (bottom > position.pixels + position.viewportDimension - margin) {
      destination = bottom - position.viewportDimension + margin;
    }
    if (destination != null) {
      controller.animateTo(
        destination.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
      );
    }
  }

  void _switchTab(bool giphySelected) {
    setState(() {
      giphyTab = giphySelected;
      selectedIndex = 0;
      giphyNavigating = false;
      selectedItemIds.clear();
      selectionAnchorId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (giphySelected ? giphyFocus : searchFocus).requestFocus();
      final scroll = giphySelected ? giphyPickerScroll : pickerScroll;
      if (scroll.hasClients) scroll.jumpTo(0);
    });
  }

  void _resetPickerList() {
    selectedIndex = 0;
    if (pickerScroll.hasClients) pickerScroll.jumpTo(0);
  }

  Future<void> _togglePicker({bool fromShortcut = false}) async {
    if (windowTransition) return;
    if (picker) {
      if (fromShortcut) {
        await _dismissPicker();
      } else {
        await _openLibrary();
      }
      return;
    }
    if (fromShortcut) {
      actions.rememberTarget();
      if (actions.previousWindow == await windowManager.getId()) {
        actions.clearTarget();
      }
    } else {
      actions.clearTarget();
    }
    windowTransition = true;
    try {
      await windowManager.hide();
      searchController.clear();
      selectedTagFilters.clear();
      setState(() {
        picker = true;
        giphyTab = false;
        selectedFolder = null;
        favoritesOnly = false;
        selectedIndex = 0;
      });
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(620, 540));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && picker) {
          searchFocus.requestFocus();
          if (pickerScroll.hasClients) pickerScroll.jumpTo(0);
        }
      });
    } finally {
      windowTransition = false;
    }
  }

  Future<void> _dismissPicker() async {
    if (!picker || windowTransition) return;
    windowTransition = true;
    try {
      await windowManager.hide();
      setState(() => picker = false);
      actions.clearTarget();
      await _restoreLibraryWindow();
    } finally {
      windowTransition = false;
    }
  }

  Future<void> _openLibrary() async {
    for (var attempt = 0; windowTransition && attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (windowTransition) return;
    if (!picker) {
      await windowManager.show();
      await windowManager.focus();
      return;
    }
    windowTransition = true;
    try {
      await windowManager.hide();
      setState(() => picker = false);
      actions.clearTarget();
      await _restoreLibraryWindow();
      await windowManager.setSize(const Size(1050, 720));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    } finally {
      windowTransition = false;
    }
  }

  Future<void> _restoreLibraryWindow() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setResizable(true);
  }

  Future<void> _changeShortcut() async {
    HotKey? recorded;
    final candidate = await showDialog<HotKey>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Quick picker shortcut'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Current: ${hotkey.debugName}'),
              const SizedBox(height: 16),
              const Text('Press a new key combination:'),
              const SizedBox(height: 8),
              HotKeyRecorder(
                onHotKeyRecorded: (value) => update(() => recorded = value),
              ),
              const SizedBox(height: 12),
              const Text(
                'Use Ctrl, Alt, or the Windows key with another key.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  recorded != null && ShortcutSettings.isUsable(recorded!)
                  ? () => Navigator.pop(context, recorded)
                  : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (candidate == null || !mounted) return;
    final sameKey =
        candidate.physicalKey == hotkey.physicalKey &&
        (candidate.modifiers ?? []).toSet().containsAll(
          hotkey.modifiers ?? [],
        ) &&
        (candidate.modifiers ?? []).length == (hotkey.modifiers ?? []).length;
    if (sameKey) return;
    try {
      await hotKeyManager.register(
        candidate,
        keyDownHandler: (_) => _togglePicker(fromShortcut: true),
      );
      await ShortcutSettings.save(candidate);
      await hotKeyManager.unregister(hotkey);
      if (mounted) setState(() => hotkey = candidate);
      windowsTray?.updateShortcutLabel(candidate.debugName);
    } catch (e) {
      await hotKeyManager.unregister(candidate).catchError((_) {});
      _showError('Shortcut unavailable: $e');
    }
  }

  Future<void> _import() async {
    const images = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'gif', 'jpg', 'jpeg', 'webp'],
      mimeTypes: ['image/png', 'image/gif', 'image/jpeg', 'image/webp'],
    );
    final picked = await openFiles(acceptedTypeGroups: [images]);
    if (Platform.isAndroid) {
      var added = 0;
      for (final file in picked) {
        try {
          final extension = file.name.split('.').last.toLowerCase();
          if (!{'png', 'gif', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
            continue;
          }
          if (await file.length() > 30 * 1024 * 1024) {
            throw const FormatException('Images must be under 30 MB');
          }
          await widget.store.importBytes(
            await file.readAsBytes(),
            name: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
            extension: extension,
            folderId: selectedFolder,
          );
          added++;
        } catch (e) {
          _showError('Could not import ${file.name}: $e');
        }
      }
      if (added > 0) {
        _showError('Imported $added ${added == 1 ? 'item' : 'items'}.');
      }
    } else {
      await _importPaths(picked.map((e) => e.path).toList());
    }
  }

  Future<bool> _importPaths(List<String> paths) async {
    if (paths.isEmpty) return false;
    final supported = paths
        .where(
          (path) => RegExp(
            r'\.(png|gif|jpe?g|webp)$',
            caseSensitive: false,
          ).hasMatch(path),
        )
        .toList();
    if (supported.isEmpty) {
      _showError('Choose PNG, GIF, JPEG, or WebP files.');
      return false;
    }
    try {
      final before = widget.store.items.length;
      await widget.store.importFiles(supported, folderId: selectedFolder);
      final added = widget.store.items.length - before;
      _showError(
        added == 0
            ? 'No images were imported.'
            : 'Imported $added ${added == 1 ? 'item' : 'items'}.',
      );
      return added > 0;
    } catch (e) {
      _showError('Import failed: $e');
      return false;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showKeyboardSetup() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use Memlib in other apps'),
        content: const Text(
          '1. Enable “Memlib stickers” in Android keyboard settings.\n\n2. Open a text field and switch to the Memlib keyboard. Tap a GIF or sticker to insert it. Long-press one to share it.',
        ),
        actions: [
          TextButton(
            onPressed: () => AndroidBridge.openKeyboardSettings(),
            child: const Text('Enable keyboard'),
          ),
          FilledButton(
            onPressed: () => AndroidBridge.showKeyboardPicker(),
            child: const Text('Switch keyboard'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial),
    );
  }

  Future<void> _useItem(LibraryItem item) async {
    try {
      await actions.copyFile(widget.store.fileFor(item));
      await widget.store.markUsed(item);
      await _afterCopy();
    } catch (e) {
      _showError('Could not copy: $e');
    }
  }

  Future<void> _afterCopy() async {
    if (!picker || !Platform.isWindows) {
      _showError('Copied to clipboard');
      return;
    }
    if (actions.previousWindow == null) {
      await _openLibrary();
      _showError('Copied to clipboard');
      return;
    }
    pasting = true;
    try {
      await windowManager.hide();
      setState(() => picker = false);
      await _restoreLibraryWindow();
      final pasted = await actions.pasteIntoPreviousWindow(hideWindow: false);
      actions.clearTarget();
      if (!pasted) {
        await windowManager.show();
        await windowManager.focus();
        _showError(
          'Copied. Automatic paste did not work; press Ctrl+V in the target app.',
        );
      }
    } finally {
      pasting = false;
    }
  }

  Future<void> _searchGiphy({bool more = false}) async {
    if (!giphy.configured || busy) return;
    final query = more ? giphyQuery : giphyController.text.trim();
    if (query.isEmpty || (more && !giphyHasMore)) return;
    final offset = more ? giphyOffset : 0;
    final request = ++giphyRequest;
    if (!more && giphyPickerScroll.hasClients) giphyPickerScroll.jumpTo(0);
    setState(() {
      busy = true;
      error = null;
      if (!more) {
        results = [];
        seenGiphy.clear();
        selectedIndex = 0;
        giphyHasMore = false;
        giphyNavigating = false;
      }
    });
    try {
      final page = await giphy.search(
        query,
        stickers: stickerSearch,
        offset: offset,
      );
      if (mounted && request == giphyRequest) {
        setState(() {
          giphyQuery = query;
          results = more ? [...results, ...page.items] : page.items;
          giphyOffset = page.nextOffset ?? 0;
          giphyHasMore = page.nextOffset != null;
        });
      }
    } catch (e) {
      if (mounted && request == giphyRequest) setState(() => error = '$e');
    } finally {
      if (mounted && request == giphyRequest) setState(() => busy = false);
    }
  }

  Future<void> _useGiphy(GiphyResult item) async {
    try {
      setState(() => busy = true);
      unawaited(giphy.track(item, GiphyAction.click));
      final bytes = await giphy.fetchForShare(item);
      await actions.copyBytes(bytes, 'gif');
      await _afterCopy();
      unawaited(giphy.track(item, GiphyAction.send));
    } catch (e) {
      _showError('Could not copy GIF: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveGiphy(
    GiphyResult item, {
    bool toggleFavorite = false,
  }) async {
    if (savingGiphy.contains(item.id) || !giphyLibrary.allowSaves) return;
    setState(() => savingGiphy.add(item.id));
    try {
      unawaited(giphy.track(item, GiphyAction.click));
      if (toggleFavorite) {
        final saved = await giphyLibrary.toggleFavorite(
          item,
          folderId: selectedFolder,
        );
        _showError(
          saved.favorite ? 'Added to favourites' : 'Removed from favourites',
        );
      } else {
        final alreadySaved = giphyLibrary.savedItem(item) != null;
        await giphyLibrary.save(item, folderId: selectedFolder);
        _showError(
          alreadySaved ? 'Already in your library' : 'Saved to your library',
        );
      }
    } catch (e) {
      _showError('Could not save GIF: $e');
    } finally {
      if (mounted) setState(() => savingGiphy.remove(item.id));
    }
  }

  LibraryFolder? get currentFolder => widget.store.folders
      .where((folder) => folder.id == selectedFolder)
      .firstOrNull;

  List<LibraryFolder> foldersIn(String? parentId) {
    final folders = widget.store.folders
        .where((folder) => folder.parentId == parentId)
        .toList();
    folders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return folders;
  }

  List<LibraryFolder> get visibleFolders {
    if (favoritesOnly ||
        searchController.text.trim().isNotEmpty ||
        selectedTagFilters.isNotEmpty) {
      return [];
    }
    return foldersIn(selectedFolder);
  }

  void _openFolder(String? id) => setState(() {
    selectedFolder = id;
    favoritesOnly = false;
    selectedIndex = 0;
    selectedItemIds.clear();
    selectionAnchorId = null;
    var parent = widget.store.folders.where((e) => e.id == id).firstOrNull;
    while (parent?.parentId != null) {
      expandedFolders.add(parent!.parentId!);
      parent = widget.store.folders
          .where((e) => e.id == parent!.parentId)
          .firstOrNull;
    }
  });

  bool _canDrop(_LibraryDrag data, String? target) {
    if (data.folder) {
      final folder = widget.store.folders
          .where((e) => e.id == data.id)
          .firstOrNull;
      return folder != null &&
          folder.parentId != target &&
          widget.store.canMoveFolder(folder, target);
    }
    final item = widget.store.items.where((e) => e.id == data.id).firstOrNull;
    return item != null && item.folderId != target;
  }

  Future<void> _drop(_LibraryDrag data, String? target) async {
    try {
      if (data.folder) {
        final folder = widget.store.folders
            .where((e) => e.id == data.id)
            .firstOrNull;
        if (folder == null) return;
        await widget.store.moveFolder(folder, target);
        if (target != null) setState(() => expandedFolders.add(target));
      } else {
        final item = widget.store.items
            .where((e) => e.id == data.id)
            .firstOrNull;
        if (item == null) return;
        await widget.store.updateItem(item, move: true, folderId: target);
      }
    } catch (e) {
      _showError('Could not move: $e');
    }
  }

  Widget _dropOn(String? target, Widget child) => DragTarget<_LibraryDrag>(
    onWillAcceptWithDetails: (details) => _canDrop(details.data, target),
    onAcceptWithDetails: (details) => _drop(details.data, target),
    builder: (context, candidates, rejects) => DecoratedBox(
      decoration: BoxDecoration(
        color: candidates.isEmpty
            ? Colors.transparent
            : const Color(0x337C5CDE),
        borderRadius: BorderRadius.circular(12),
        border: candidates.isEmpty
            ? null
            : Border.all(color: const Color(0xFFBDA7FF)),
      ),
      child: child,
    ),
  );

  Widget _drag(_LibraryDrag data, String label, IconData icon, Widget child) {
    final feedback = Material(
      color: const Color(0xFF382B56),
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
    if (Theme.of(context).platform == TargetPlatform.android) {
      if (!data.folder) return child;
      return LongPressDraggable<_LibraryDrag>(
        data: data,
        feedback: feedback,
        childWhenDragging: Opacity(opacity: .4, child: child),
        child: child,
      );
    }
    return Draggable<_LibraryDrag>(
      data: data,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: .4, child: child),
      child: child,
    );
  }

  List<LibraryItem> get visibleItems {
    final query = searchController.text.trim().toLowerCase();
    final items = widget.store.items
        .where(
          (item) =>
              (picker && selectedFolder == null ||
                  searchController.text.trim().isNotEmpty ||
                  selectedTagFilters.isNotEmpty ||
                  favoritesOnly ||
                  item.folderId == selectedFolder) &&
              (!favoritesOnly || item.favorite) &&
              selectedTagFilters.every(
                (selected) => item.tags.any(
                  (tag) => tag.toLowerCase() == selected.toLowerCase(),
                ),
              ) &&
              (query.isEmpty ||
                  item.name.toLowerCase().contains(query) ||
                  item.tags.any((tag) => tag.toLowerCase().contains(query))),
        )
        .toList();
    items.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      return b.useCount.compareTo(a.useCount);
    });
    return items;
  }

  List<LibraryItem> get selectedItems => widget.store.items
      .where((item) => selectedItemIds.contains(item.id))
      .toList();

  List<String> get availableTags {
    final tags = <String, String>{};
    for (final item in widget.store.items) {
      for (final tag in item.tags) {
        tags.putIfAbsent(tag.toLowerCase(), () => tag);
      }
    }
    return tags.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  Future<String?> _chooseTag(int itemCount) async {
    var query = '';
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final matches = availableTags
              .where((tag) => tag.toLowerCase().contains(query.toLowerCase()))
              .toList();
          return AlertDialog(
            title: Text('Add tag to $itemCount items'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (value) => update(() => query = value.trim()),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        Navigator.pop(context, value.trim());
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Search or create a tag',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  if (matches.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Existing tags'),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 180,
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          title: Text(matches[index]),
                          leading: const Icon(Icons.sell_outlined, size: 18),
                          onTap: () => Navigator.pop(context, matches[index]),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: query.isEmpty
                    ? null
                    : () => Navigator.pop(context, query),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showTagFilters() async {
    var query = '';
    final pending = {...selectedTagFilters};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final matches = availableTags
              .where((tag) => tag.toLowerCase().contains(query.toLowerCase()))
              .toList();
          return AlertDialog(
            title: const Text('Filter by tags'),
            content: SizedBox(
              width: 380,
              height: 320,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (value) => update(() => query = value.trim()),
                    decoration: const InputDecoration(
                      hintText: 'Search tags',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? const Center(child: Text('No matching tags'))
                        : ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (context, index) {
                              final tag = matches[index];
                              return CheckboxListTile(
                                dense: true,
                                title: Text(tag),
                                value: pending.contains(tag),
                                onChanged: (checked) => update(() {
                                  if (checked == true) {
                                    pending.add(tag);
                                  } else {
                                    pending.remove(tag);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => update(pending.clear),
                child: const Text('Clear'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, pending),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      selectedTagFilters
        ..clear()
        ..addAll(result);
      selectedItemIds.clear();
      selectionAnchorId = null;
      if (picker) _resetPickerList();
    });
  }

  Widget _tagFilterButton() => OutlinedButton.icon(
    onPressed: _showTagFilters,
    icon: const Icon(Icons.filter_alt_outlined, size: 18),
    label: Text(
      selectedTagFilters.isEmpty
          ? 'Tags'
          : 'Tags (${selectedTagFilters.length})',
    ),
  );

  void _clearSelection() => setState(() {
    selectedItemIds.clear();
    selectionAnchorId = null;
  });

  void _selectLibraryItem(LibraryItem item, {bool checkbox = false}) {
    final keyboard = HardwareKeyboard.instance;
    final shift = Platform.isWindows && keyboard.isShiftPressed;
    final control =
        Platform.isWindows &&
        (keyboard.isControlPressed || keyboard.isMetaPressed);
    final order = visibleItems;
    setState(() {
      if (shift) {
        final from = order.indexWhere((entry) => entry.id == selectionAnchorId);
        final to = order.indexWhere((entry) => entry.id == item.id);
        if (from >= 0 && to >= 0) {
          if (!control) selectedItemIds.clear();
          final low = from < to ? from : to;
          final high = from > to ? from : to;
          for (var i = low; i <= high; i++) {
            selectedItemIds.add(order[i].id);
          }
          return;
        }
      }
      if (control || checkbox) {
        if (!selectedItemIds.add(item.id)) selectedItemIds.remove(item.id);
      } else {
        selectedItemIds
          ..clear()
          ..add(item.id);
      }
      selectionAnchorId = item.id;
    });
  }

  void _selectItemAt(Offset globalPosition) {
    if (!mobileSelecting || !libraryGridScroll.hasClients) return;
    final box = libraryGridKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(globalPosition);
    if (local.dx < 0 || local.dx > box.size.width) return;
    final position = libraryGridScroll.position;
    if (local.dy < 32 && position.pixels > position.minScrollExtent) {
      libraryGridScroll.jumpTo(
        (position.pixels - 20).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    } else if (local.dy > box.size.height - 32 &&
        position.pixels < position.maxScrollExtent) {
      libraryGridScroll.jumpTo(
        (position.pixels + 20).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
    final width = box.size.width - 32;
    final columns = (width / (190 + 12)).ceil().clamp(1, 100);
    final tileWidth = (width - (columns - 1) * 12) / columns;
    final strideY = tileWidth / 0.85 + 12;
    final column = ((local.dx - 16) / (tileWidth + 12)).floor();
    final row = ((local.dy + position.pixels) / strideY).floor();
    if (column < 0 || column >= columns || row < 0) return;
    final index = row * columns + column - visibleFolders.length;
    final items = visibleItems;
    if (index >= 0 && index < items.length) {
      setState(() => selectedItemIds.add(items[index].id));
    }
  }

  Future<String?> _chooseMoveFolder() => showDialog<String>(
    context: context,
    builder: (context) {
      final tiles = <Widget>[];
      final visited = <String>{};
      void addChildren(String? parentId, int depth) {
        for (final folder in foldersIn(parentId)) {
          if (!visited.add(folder.id)) continue;
          tiles.add(
            ListTile(
              contentPadding: EdgeInsets.only(
                left: 16.0 + depth * 18,
                right: 16,
              ),
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.name),
              onTap: () => Navigator.pop(context, folder.id),
            ),
          );
          addChildren(folder.id, depth + 1);
        }
      }

      addChildren(null, 0);
      return AlertDialog(
        title: const Text('Move selected items'),
        content: SizedBox(
          width: 360,
          height: 360,
          child: ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: const Text('Library root'),
                onTap: () => Navigator.pop(context, ''),
              ),
              ...tiles,
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );

  Widget _selectionToolbar() {
    final items = selectedItems;
    final tags = items.expand((item) => item.tags).toSet().toList()..sort();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2540),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF665286)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${items.length} selected',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextButton.icon(
                icon: const Icon(Icons.sell_outlined, size: 18),
                label: const Text('Add tag'),
                onPressed: () async {
                  final tag = await _chooseTag(items.length);
                  if (tag != null) await widget.store.addTagToItems(items, tag);
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('Move'),
                onPressed: () async {
                  final folder = await _chooseMoveFolder();
                  if (folder == null) return;
                  await widget.store.moveItems(
                    items,
                    folder.isEmpty ? null : folder,
                  );
                  _clearSelection();
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete'),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Delete ${items.length} items?'),
                      content: const Text(
                        'This removes the selected media from your library.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.store.deleteItems(items);
                    _clearSelection();
                  }
                },
              ),
              IconButton(
                tooltip: 'Clear selection',
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
            ],
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 5),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final tag in tags)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InputChip(
                        label: Text(tag),
                        onDeleted: () =>
                            widget.store.removeTagFromItems(items, tag),
                        deleteIcon: const Icon(Icons.close, size: 16),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _switchMainTab(int tab) => _switchTab(tab == 1);

  Future<void> _importClipboardFiles() async {
    try {
      final paths = await Pasteboard.files();
      if (!mounted) return;
      if (paths.isEmpty) {
        _showError('No files found on the clipboard.');
        return;
      }
      await _importPaths(paths);
    } catch (e) {
      _showError('Could not import clipboard files: $e');
    }
  }

  Future<void> _accountAction(String action) async {
    final cloud = widget.cloud;
    if (cloud == null) return;
    try {
      if (action == 'sync') await cloud.syncNow();
      if (action == 'signout') await cloud.signOut();
      if (action == 'import') {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Import local library?'),
            content: const Text(
              'Copy your guest folders and media into this account. Your existing cloud library stays in place.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Import'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          final count = await cloud.importGuestLibrary();
          if (mounted) _showError('Imported $count items. Syncing now.');
        }
      }
      if (cloud.syncError != null && mounted) {
        _showError(cloud.syncError!);
      }
    } catch (e) {
      if (mounted) _showError('Account action failed: $e');
    }
  }

  Widget _accountButton() {
    final cloud = widget.cloud;
    if (cloud == null || !cloud.configured) return const SizedBox.shrink();
    if (!cloud.signedIn) {
      return TextButton.icon(
        onPressed: () => showDialog<bool>(
          context: context,
          builder: (_) => AccountDialog(cloud: cloud),
        ),
        icon: const Icon(Icons.person_outline),
        label: const Text('Sign in'),
      );
    }
    return PopupMenuButton<String>(
      tooltip:
          cloud.syncError ?? (cloud.syncing ? 'Syncing' : 'Account and sync'),
      icon: Icon(
        cloud.syncError != null
            ? Icons.cloud_off_outlined
            : cloud.syncing
            ? Icons.sync
            : Icons.cloud_done_outlined,
      ),
      onSelected: (value) => unawaited(_accountAction(value)),
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            cloud.email ?? 'Signed in',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            cloud.syncError != null
                ? 'Sync needs attention'
                : cloud.syncing
                ? 'Syncing…'
                : cloud.lastSyncedAt == null
                ? 'Waiting to sync'
                : 'Up to date',
          ),
        ),
        const PopupMenuItem(value: 'sync', child: Text('Sync now')),
        if (cloud.guestLibraryAvailable)
          const PopupMenuItem(
            value: 'import',
            child: Text('Import local library'),
          ),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720 && !picker;
    final content = picker
        ? _pickerView()
        : Row(
            children: [
              if (wide) SizedBox(width: 250, child: _sidebar()),
              Expanded(
                child: Column(
                  children: [
                    if (!picker && widget.cloud?.syncError != null)
                      MaterialBanner(
                        content: Text(
                          widget.cloud!.syncError!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        actions: [
                          if (widget.cloud!.conflict != null) ...[
                            TextButton(
                              onPressed: () => unawaited(
                                widget.cloud!.resolveConflict(
                                  keepDevice: false,
                                ),
                              ),
                              child: const Text('Use cloud'),
                            ),
                            TextButton(
                              onPressed: () => unawaited(
                                widget.cloud!.resolveConflict(keepDevice: true),
                              ),
                              child: const Text('Keep device'),
                            ),
                          ] else
                            TextButton(
                              onPressed: () =>
                                  unawaited(widget.cloud!.syncNow()),
                              child: const Text('Retry'),
                            ),
                        ],
                      ),
                    if (!picker)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 0,
                              label: Text('Library'),
                              icon: Icon(Icons.collections_outlined),
                            ),
                            ButtonSegment(
                              value: 1,
                              label: Text('GIPHY'),
                              icon: Icon(Icons.search),
                            ),
                          ],
                          selected: {giphyTab ? 1 : 0},
                          onSelectionChanged: (v) => _switchMainTab(v.first),
                        ),
                      ),
                    if (giphyTab && !picker)
                      Expanded(child: _giphyView())
                    else
                      Expanded(child: _libraryView(wide)),
                  ],
                ),
              ),
            ],
          );
    return Scaffold(
      appBar: picker
          ? null
          : AppBar(
              title: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_mosaic_rounded,
                    color: Color(0xFFBDA7FF),
                  ),
                  SizedBox(width: 10),
                  Text('Memlib', style: TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
              actions: [
                _accountButton(),
                if (Platform.isWindows)
                  IconButton(
                    tooltip: picker
                        ? 'Open library'
                        : 'Quick picker · ${hotkey.debugName}',
                    icon: Icon(picker ? Icons.open_in_full : Icons.bolt),
                    onPressed: () => _togglePicker(),
                  ),
                if (Platform.isAndroid)
                  PopupMenuButton<String>(
                    tooltip: 'Android tools',
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    onSelected: (value) {
                      if (value == 'keyboard') unawaited(_showKeyboardSetup());
                      if (value == 'paste') {
                        unawaited(
                          AndroidBridge.importClipboardImage().catchError((
                            Object e,
                          ) {
                            _showError('Could not import clipboard image: $e');
                          }),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'keyboard',
                        child: Text('Set up keyboard'),
                      ),
                      PopupMenuItem(
                        value: 'paste',
                        child: Text('Import image from clipboard'),
                      ),
                    ],
                  ),
                if (Platform.isWindows && !picker)
                  PopupMenuButton<String>(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined),
                    onSelected: (value) {
                      if (value == 'shortcut') unawaited(_changeShortcut());
                      if (value == 'startup') unawaited(_toggleStartup());
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'shortcut',
                        child: Text('Change picker shortcut'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'startup',
                        checked: startupEnabled,
                        child: const Text('Launch at sign-in'),
                      ),
                    ],
                  ),
                if (!picker)
                  IconButton(
                    tooltip: 'Import files',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _import,
                  ),
              ],
            ),
      body: Platform.isWindows && !picker
          ? DropTarget(
              onDragEntered: (_) => setState(() => draggingFiles = true),
              onDragExited: (_) => setState(() => draggingFiles = false),
              onDragDone: (details) {
                setState(() => draggingFiles = false);
                unawaited(
                  _importPaths(details.files.map((file) => file.path).toList()),
                );
              },
              child: Stack(
                children: [
                  content,
                  if (draggingFiles)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: const Color(0xE0181426),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.file_download_outlined,
                                  size: 60,
                                  color: Color(0xFFBDA7FF),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Drop images to import',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  selectedFolder == null
                                      ? 'Into your library'
                                      : 'Into ${widget.store.folders.where((folder) => folder.id == selectedFolder).firstOrNull?.name ?? 'your library'}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          : content,
    );
  }

  Widget _pickerView() {
    final items = visibleItems;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1623),
        border: Border.all(color: const Color(0xFF514462)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
            child: Row(
              children: [
                const Icon(Icons.bolt, color: Color(0xFFBDA7FF), size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Memlib',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Open library',
                  icon: const Icon(Icons.open_in_full, size: 18),
                  onPressed: _openLibrary,
                ),
                IconButton(
                  tooltip: 'Close popup',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _dismissPicker,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Your library'),
                  avatar: const Icon(Icons.collections_outlined, size: 16),
                  selected: !giphyTab,
                  onSelected: (_) => _switchTab(false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('GIPHY'),
                  avatar: const Icon(Icons.search, size: 16),
                  selected: giphyTab,
                  onSelected: (_) => _switchTab(true),
                ),
              ],
            ),
          ),
          if (giphyTab)
            Expanded(child: _giphyView(compact: true))
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      focusNode: searchFocus,
                      controller: searchController,
                      onChanged: (_) => setState(_resetPickerList),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Search items and tags',
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF2A2435),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _tagFilterButton(),
                ],
              ),
            ),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: selectedFolder == null && !favoritesOnly,
                    onSelected: (_) => setState(() {
                      selectedFolder = null;
                      favoritesOnly = false;
                      _resetPickerList();
                    }),
                  ),
                  const SizedBox(width: 7),
                  ChoiceChip(
                    label: const Text('★ Favourites'),
                    selected: favoritesOnly,
                    onSelected: (_) => setState(() {
                      selectedFolder = null;
                      favoritesOnly = true;
                      _resetPickerList();
                    }),
                  ),
                  ...widget.store.folders.map(
                    (folder) => Padding(
                      padding: const EdgeInsets.only(left: 7),
                      child: ChoiceChip(
                        label: Text(folder.name),
                        selected: selectedFolder == folder.id,
                        onSelected: (_) => setState(() {
                          selectedFolder = folder.id;
                          favoritesOnly = false;
                          _resetPickerList();
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        'No matching items',
                        style: TextStyle(color: Colors.white60),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        pickerGridWidth = constraints.maxWidth;
                        return GridView.builder(
                          controller: pickerScroll,
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                childAspectRatio: 1.0,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                          itemCount: items.length,
                          itemBuilder: (context, index) => _itemCard(
                            items[index],
                            selected: index == selectedIndex,
                          ),
                        );
                      },
                    ),
            ),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              giphyTab
                  ? 'Search GIPHY   ·   Arrow keys to move   ·   Enter to paste   ·   Esc to close'
                  : 'Type to search   ·   Arrow keys to move   ·   Enter to paste   ·   Esc to close',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderTile(LibraryFolder folder, {int depth = 0}) {
    final children = foldersIn(folder.id);
    final expanded = expandedFolders.contains(folder.id);
    final tile = Padding(
      padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8, top: 2),
      child: _dropOn(
        folder.id,
        ListTile(
          key: ValueKey('sidebar-folder-${folder.id}'),
          dense: true,
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          leading: IconButton(
            tooltip: expanded
                ? 'Collapse ${folder.name}'
                : 'Expand ${folder.name}',
            icon: Icon(
              children.isEmpty
                  ? Icons.folder_outlined
                  : (expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right),
            ),
            onPressed: children.isEmpty
                ? null
                : () => setState(() {
                    if (expanded) {
                      expandedFolders.remove(folder.id);
                    } else {
                      expandedFolders.add(folder.id);
                    }
                  }),
          ),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          selected: selectedFolder == folder.id && !favoritesOnly,
          onTap: () => _openFolder(folder.id),
          trailing: PopupMenuButton<String>(
            tooltip: 'Folder options',
            onSelected: (action) async {
              if (action == 'new') {
                final name = await _askName('New subfolder');
                if (name != null) {
                  await widget.store.addFolder(name, parentId: folder.id);
                  setState(() => expandedFolders.add(folder.id));
                }
              } else if (action == 'rename') {
                final name = await _askName(
                  'Rename folder',
                  initial: folder.name,
                );
                if (name != null) await widget.store.renameFolder(folder, name);
              } else if (action == 'delete') {
                if (selectedFolder == folder.id) _openFolder(folder.parentId);
                await widget.store.deleteFolder(folder);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'new', child: Text('New subfolder')),
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Remove folder; keep contents'),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      children: [
        _drag(_LibraryDrag.folder(folder.id), folder.name, Icons.folder, tile),
        if (expanded)
          for (final child in children) _folderTile(child, depth: depth + 1),
      ],
    );
  }

  Widget _sidebar() => Material(
    color: const Color(0xFF1C1924),
    child: Column(
      children: [
        _dropOn(
          null,
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Library root'),
            selected: selectedFolder == null && !favoritesOnly,
            onTap: () => _openFolder(null),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.star_outline),
          title: const Text('Favourites'),
          selected: favoritesOnly,
          onTap: () => setState(() {
            selectedFolder = null;
            favoritesOnly = true;
            selectedItemIds.clear();
            selectionAnchorId = null;
          }),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              const Expanded(child: Text('FOLDERS')),
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final name = await _askName('New folder');
                  if (name != null) {
                    await widget.store.addFolder(
                      name,
                      parentId: selectedFolder,
                    );
                    if (selectedFolder != null) {
                      setState(() => expandedFolders.add(selectedFolder!));
                    }
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final folder in foldersIn(null)) _folderTile(folder),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _libraryView(bool wide) => Column(
    children: [
      if (selectedFolder != null &&
          !favoritesOnly &&
          searchController.text.trim().isEmpty &&
          selectedTagFilters.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _dropOn(
                  null,
                  TextButton.icon(
                    onPressed: () => _openFolder(null),
                    icon: const Icon(Icons.home_outlined, size: 18),
                    label: const Text('Library'),
                  ),
                ),
                for (final folder in _folderPath()) ...[
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Colors.white54,
                  ),
                  TextButton(
                    onPressed: () => _openFolder(folder.id),
                    child: Text(folder.name),
                  ),
                ],
              ],
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    searchController.text.trim().isNotEmpty ||
                            selectedTagFilters.isNotEmpty
                        ? 'Search results'
                        : favoritesOnly
                        ? 'Favourites'
                        : currentFolder?.name ?? 'Your library',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${visibleFolders.length} ${visibleFolders.length == 1 ? 'folder' : 'folders'} · ${visibleItems.length} ${visibleItems.length == 1 ? 'item' : 'items'}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!favoritesOnly &&
                searchController.text.trim().isEmpty &&
                selectedTagFilters.isEmpty)
              IconButton(
                tooltip: 'New folder',
                onPressed: () async {
                  final name = await _askName(
                    selectedFolder == null ? 'New folder' : 'New subfolder',
                  );
                  if (name != null) {
                    await widget.store.addFolder(
                      name,
                      parentId: selectedFolder,
                    );
                  }
                },
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            if (wide)
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Import'),
              ),
          ],
        ),
      ),
      if (!wide)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _dropOn(
                null,
                ChoiceChip(
                  label: const Text('Library root'),
                  selected: selectedFolder == null && !favoritesOnly,
                  onSelected: (_) => _openFolder(null),
                ),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('★ Favourites'),
                selected: favoritesOnly,
                onSelected: (_) => setState(() {
                  selectedFolder = null;
                  favoritesOnly = true;
                  selectedItemIds.clear();
                  selectionAnchorId = null;
                }),
              ),
              ...foldersIn(null).map(
                (folder) => Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    label: Text(folder.name),
                    selected: selectedFolder == folder.id,
                    onSelected: (_) => _openFolder(folder.id),
                  ),
                ),
              ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                focusNode: searchFocus,
                controller: searchController,
                onChanged: (_) => setState(() {
                  selectedItemIds.clear();
                  selectionAnchorId = null;
                }),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search names and tags',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _tagFilterButton(),
          ],
        ),
      ),
      if (selectedItemIds.isNotEmpty) _selectionToolbar(),
      Expanded(
        child: visibleItems.isEmpty && visibleFolders.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 92,
                          height: 92,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2D2540),
                            borderRadius: BorderRadius.circular(26),
                          ),
                          child: const Icon(
                            Icons.collections_bookmark_outlined,
                            size: 46,
                            color: Color(0xFFBDA7FF),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          widget.store.items.isEmpty
                              ? 'Build your collection'
                              : 'Nothing found',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.store.items.isEmpty
                              ? Platform.isAndroid
                                    ? 'Import GIFs and stickers, then reach them from any text field with the Memlib keyboard.'
                                    : 'Import GIFs and stickers, then reach them from anywhere with the quick picker.'
                              : 'Try another search or choose a different folder.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: _import,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Import images'),
                        ),
                        if (Platform.isWindows)
                          const Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: Text(
                              'Drop images here, or copy image files in Explorer and press Ctrl+V',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              )
            : GridView.builder(
                key: libraryGridKey,
                controller: libraryGridScroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: picker ? 140 : 190,
                  childAspectRatio: 0.85,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: visibleFolders.length + visibleItems.length,
                itemBuilder: (context, index) => index < visibleFolders.length
                    ? _folderCard(visibleFolders[index])
                    : _drag(
                        _LibraryDrag.item(
                          visibleItems[index - visibleFolders.length].id,
                        ),
                        visibleItems[index - visibleFolders.length].name,
                        Icons.image_outlined,
                        _itemCard(visibleItems[index - visibleFolders.length]),
                      ),
              ),
      ),
      if (picker && Platform.isWindows)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Ctrl+Alt+V · Tap an item to paste into the previous app',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
    ],
  );

  List<LibraryFolder> _folderPath() {
    final path = <LibraryFolder>[];
    final seen = <String>{};
    var folder = currentFolder;
    while (folder != null && seen.add(folder.id)) {
      path.insert(0, folder);
      folder = widget.store.folders
          .where((e) => e.id == folder!.parentId)
          .firstOrNull;
    }
    return path;
  }

  Widget _folderCard(LibraryFolder folder) {
    final subfolders = foldersIn(folder.id).length;
    final items = widget.store.items
        .where((item) => item.folderId == folder.id)
        .length;
    final card = _dropOn(
      folder.id,
      Card(
        key: ValueKey('folder-card-${folder.id}'),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: () => _openFolder(folder.id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.folder_rounded,
                      size: 72,
                      color: const Color(0xFFBDA7FF).withValues(alpha: .9),
                    ),
                  ),
                ),
                Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '$subfolders folders · $items items',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return _drag(
      _LibraryDrag.folder(folder.id),
      folder.name,
      Icons.folder,
      card,
    );
  }

  Widget _itemCard(LibraryItem item, {bool selected = false}) {
    final card = Card(
      key: picker
          ? ValueKey('picker-${item.id}')
          : ValueKey('item-card-${item.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected || (!picker && selectedItemIds.contains(item.id))
              ? const Color(0xFFBDA7FF)
              : Colors.transparent,
          width: selected || (!picker && selectedItemIds.contains(item.id))
              ? 2
              : 0,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (picker) {
            _useItem(item);
          } else if (selectedItemIds.isNotEmpty ||
              (Platform.isWindows &&
                  (HardwareKeyboard.instance.isShiftPressed ||
                      HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed))) {
            _selectLibraryItem(item);
          } else {
            _useItem(item);
          }
        },
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.file(
                      widget.store.fileFor(item),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                  if (item.sourceType == 'giphy')
                    const Positioned(
                      left: 5,
                      bottom: 5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0xD91B1724),
                          borderRadius: BorderRadius.all(Radius.circular(5)),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            'GIPHY',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!picker)
                    Positioned(
                      top: 2,
                      left: 2,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Checkbox(
                          key: ValueKey('select-${item.id}'),
                          value: selectedItemIds.contains(item.id),
                          onChanged: (_) =>
                              _selectLibraryItem(item, checkbox: true),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton.filledTonal(
                      tooltip: item.favorite
                          ? 'Remove favourite'
                          : 'Add favourite',
                      iconSize: 18,
                      icon: Icon(
                        item.favorite ? Icons.star : Icons.star_border,
                      ),
                      onPressed: () => widget.store.updateItem(
                        item,
                        favorite: !item.favorite,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!picker)
                    PopupMenuButton<String>(
                      tooltip: 'Item options',
                      onSelected: (action) async {
                        if (action == 'rename') {
                          final name = await _askName(
                            'Rename item',
                            initial: item.name,
                          );
                          if (name != null) {
                            await widget.store.updateItem(item, name: name);
                          }
                        }
                        if (action == 'delete') {
                          await widget.store.deleteItem(item);
                        }
                        if (action == 'source' && item.sourcePage != null) {
                          await Clipboard.setData(
                            ClipboardData(text: item.sourcePage!),
                          );
                          _showError('Source link copied');
                        }
                        if (action == 'share' && Platform.isAndroid) {
                          await AndroidBridge.shareFile(
                            widget.store.fileFor(item),
                          );
                        }
                        if (action.startsWith('move:')) {
                          await widget.store.updateItem(
                            item,
                            move: true,
                            folderId: action.substring(5).isEmpty
                                ? null
                                : action.substring(5),
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        if (Platform.isAndroid)
                          const PopupMenuItem(
                            value: 'share',
                            child: Text('Share to another app'),
                          ),
                        if (item.sourcePage != null)
                          const PopupMenuItem(
                            value: 'source',
                            child: Text('Copy source link'),
                          ),
                        const PopupMenuItem(
                          value: 'move:',
                          child: Text('Move to All items'),
                        ),
                        ...widget.store.folders.map(
                          (folder) => PopupMenuItem(
                            value: 'move:${folder.id}',
                            child: Text('Move to ${folder.name}'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (!picker && item.tags.isNotEmpty)
              SizedBox(
                height: 19,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      item.tags.map((tag) => '#$tag').join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFFBDA7FF),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!picker && Theme.of(context).platform == TargetPlatform.android) {
      return GestureDetector(
        onLongPressStart: (_) => setState(() {
          mobileSelecting = true;
          selectedItemIds.add(item.id);
          selectionAnchorId = item.id;
        }),
        onLongPressMoveUpdate: (details) =>
            _selectItemAt(details.globalPosition),
        onLongPressEnd: (_) => mobileSelecting = false,
        onLongPressCancel: () => mobileSelecting = false,
        child: card,
      );
    }
    return card;
  }

  Widget _giphyView({bool compact = false}) => Column(
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 14 : 16,
          0,
          compact ? 14 : 16,
          10,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                focusNode: giphyFocus,
                controller: giphyController,
                textInputAction: TextInputAction.search,
                onChanged: (_) => giphyNavigating = false,
                onSubmitted: (_) => _searchGiphy(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search GIPHY',
                  isDense: compact,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy || !giphy.configured
                  ? null
                  : () => _searchGiphy(),
              child: const Text('Search'),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 16),
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('GIFs'),
              selected: !stickerSearch,
              onSelected: busy
                  ? null
                  : (_) {
                      setState(() => stickerSearch = false);
                      if (giphyController.text.trim().isNotEmpty) {
                        _searchGiphy();
                      }
                    },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Stickers'),
              selected: stickerSearch,
              onSelected: busy
                  ? null
                  : (_) {
                      setState(() => stickerSearch = true);
                      if (giphyController.text.trim().isNotEmpty) {
                        _searchGiphy();
                      }
                    },
            ),
            const Spacer(),
            const Text(
              'Powered by GIPHY',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      if (busy) const LinearProgressIndicator(minHeight: 2),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      if (!compact && !GiphyService.librarySavesEnabled)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Saving to the library will unlock after GIPHY permission is enabled for this build.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
        ),
      Expanded(
        child: !giphy.configured
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.key_outlined, size: 42, color: Colors.white54),
                      SizedBox(height: 12),
                      Text(
                        'Add a GIPHY API key to search',
                        style: TextStyle(fontSize: 16),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'See README.md for setup',
                        style: TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
              )
            : results.isEmpty
            ? Center(
                child: Text(
                  busy
                      ? 'Searching GIPHY…'
                      : giphyQuery.isEmpty
                      ? 'Search for a reaction or sticker'
                      : 'No results found',
                  style: const TextStyle(color: Colors.white60),
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  if (compact) giphyPickerGridWidth = constraints.maxWidth;
                  return GridView.builder(
                    controller: compact ? giphyPickerScroll : null,
                    padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 16,
                      4,
                      compact ? 14 : 16,
                      12,
                    ),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: compact ? 145 : 180,
                      childAspectRatio: 0.94,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final item = results[index];
                      final selected = compact && index == selectedIndex;
                      final saved = giphyLibrary.savedItem(item);
                      final saving = savingGiphy.contains(item.id);
                      return Card(
                        key: compact ? ValueKey('giphy-${item.id}') : null,
                        clipBehavior: Clip.antiAlias,
                        margin: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: selected
                                ? const Color(0xFFBDA7FF)
                                : Colors.transparent,
                            width: selected ? 2 : 0,
                          ),
                        ),
                        child: InkWell(
                          onTap: busy ? null : () => _useGiphy(item),
                          child: Column(
                            children: [
                              Expanded(
                                child: Image.network(
                                  item.previewUrl,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  frameBuilder:
                                      (
                                        context,
                                        child,
                                        frame,
                                        loadedSynchronously,
                                      ) {
                                        if ((frame != null ||
                                                loadedSynchronously) &&
                                            seenGiphy.add(item.id)) {
                                          unawaited(
                                            giphy.track(item, GiphyAction.load),
                                          );
                                        }
                                        return child;
                                      },
                                  errorBuilder: (_, _, _) => const Center(
                                    child: Icon(Icons.broken_image_outlined),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 8,
                                  right: 4,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.title.isEmpty
                                            ? 'GIPHY'
                                            : item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                    if (GiphyService.librarySavesEnabled) ...[
                                      IconButton(
                                        tooltip: saved == null
                                            ? 'Save to library'
                                            : 'Saved to library',
                                        visualDensity: VisualDensity.compact,
                                        constraints: compact
                                            ? const BoxConstraints.tightFor(
                                                width: 32,
                                                height: 32,
                                              )
                                            : null,
                                        padding: compact
                                            ? EdgeInsets.zero
                                            : null,
                                        iconSize: compact ? 18 : 19,
                                        onPressed:
                                            saving || busy || saved != null
                                            ? null
                                            : () => _saveGiphy(item),
                                        icon: Icon(
                                          saved == null
                                              ? Icons.download_outlined
                                              : Icons.check_circle_outline,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: saved?.favorite == true
                                            ? 'Remove favourite'
                                            : 'Add favourite',
                                        visualDensity: VisualDensity.compact,
                                        constraints: compact
                                            ? const BoxConstraints.tightFor(
                                                width: 32,
                                                height: 32,
                                              )
                                            : null,
                                        padding: compact
                                            ? EdgeInsets.zero
                                            : null,
                                        iconSize: compact ? 18 : 19,
                                        onPressed: saving || busy
                                            ? null
                                            : () => _saveGiphy(
                                                item,
                                                toggleFavorite: true,
                                              ),
                                        icon: Icon(
                                          saved?.favorite == true
                                              ? Icons.star
                                              : Icons.star_border,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
      if (giphyHasMore && results.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextButton.icon(
            onPressed: busy ? null : () => _searchGiphy(more: true),
            icon: const Icon(Icons.expand_more),
            label: const Text('More results'),
          ),
        ),
    ],
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (_) => Navigator.pop(context, controller.text),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}
