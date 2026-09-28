import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
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
import 'release_updater.dart';
import 'shortcut_settings.dart';
import 'theme.dart';
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
    theme: buildMemlibTheme(),
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
  const _LibraryDrag.items(this.itemIds) : id = '', folder = false;
  const _LibraryDrag.folder(this.id) : itemIds = const [], folder = true;
  final String id;
  final List<String> itemIds;
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
  static const _pickerPageSize = 16;
  static const _libraryPageSize = 24;
  int _pickerLoadedCount = _pickerPageSize;
  int _libraryLoadedCount = _libraryPageSize;
  bool _pickerLoadingMore = false;
  bool _libraryLoadingMore = false;
  bool _pickerLoadQueued = false;
  bool _libraryLoadQueued = false;
  int _pickerLoadGeneration = 0;
  int _libraryLoadGeneration = 0;
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
    if (kReleaseMode && (Platform.isWindows || Platform.isAndroid)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_checkForUpdates(automatic: true));
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

  void _resetLibraryList() {
    _libraryLoadGeneration++;
    _libraryLoadedCount = _libraryPageSize;
    _libraryLoadingMore = false;
    _libraryLoadQueued = false;
    if (libraryGridScroll.hasClients) libraryGridScroll.jumpTo(0);
  }

  void _queueLibraryPage(int total) {
    if (_libraryLoadQueued || _libraryLoadedCount >= total) return;
    _libraryLoadQueued = true;
    final generation = _libraryLoadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _libraryLoadGeneration) return;
      setState(() {
        _libraryLoadingMore = true;
        _libraryLoadedCount = (_libraryLoadedCount + _libraryPageSize)
            .clamp(0, total)
            .toInt();
        _libraryLoadQueued = false;
      });
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (mounted && generation == _libraryLoadGeneration) {
          setState(() => _libraryLoadingMore = false);
        }
      });
    });
  }

  void _queuePickerPage(int total) {
    if (_pickerLoadQueued || _pickerLoadedCount >= total) return;
    _pickerLoadQueued = true;
    final generation = _pickerLoadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _pickerLoadGeneration) return;
      setState(() {
        _pickerLoadingMore = true;
        _pickerLoadedCount = (_pickerLoadedCount + _pickerPageSize)
            .clamp(0, total)
            .toInt();
        _pickerLoadQueued = false;
      });
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (mounted && generation == _pickerLoadGeneration) {
          setState(() => _pickerLoadingMore = false);
        }
      });
    });
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
        _pickerLoadedCount = _pickerPageSize;
        _libraryLoadedCount = _libraryPageSize;
        _pickerLoadGeneration++;
        _libraryLoadGeneration++;
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
          giphyTab
              ? results.length
              : visibleItems.length + (picker ? visibleFolders.length : 0),
          giphyTab ? _giphyPickerColumns : _pickerColumns,
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
        final folders = picker ? visibleFolders : const <LibraryFolder>[];
        if (selectedIndex < folders.length) {
          _openFolder(folders[selectedIndex].id);
        } else {
          final items = visibleItems;
          final itemIndex = selectedIndex - folders.length;
          if (itemIndex >= 0 && itemIndex < items.length) {
            unawaited(_useItem(items[itemIndex]));
          }
        }
      }
      return true;
    }
    return false;
  }

  void _selectPickerIndex(int index) {
    setState(() {
      selectedIndex = index;
      if (index >= visibleFolders.length + _pickerLoadedCount) {
        _pickerLoadedCount = (index - visibleFolders.length + 1)
            .clamp(0, visibleItems.length)
            .toInt();
      }
    });
    final itemsLength = giphyTab
        ? results.length
        : visibleItems.length + (picker ? visibleFolders.length : 0);
    if (index < 0 || index >= itemsLength) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !picker || selectedIndex != index) return;
      _scrollPickerSelectionIntoView(index);
    });
  }

  int get _giphyPickerColumns =>
      ((giphyPickerGridWidth - _pickerPad * 2) /
              (_giphyPickerExtent + _pickerGap))
          .ceil()
          .clamp(1, 100);

  void _scrollPickerSelectionIntoView(int index) {
    final controller = giphyTab ? giphyPickerScroll : pickerScroll;
    if (!controller.hasClients) return;
    final columns = giphyTab ? _giphyPickerColumns : _pickerColumns;
    final width = giphyTab ? giphyPickerGridWidth : pickerGridWidth;
    const spacing = _pickerGap;
    final tileWidth =
        (width - _pickerPad * 2 - (columns - 1) * spacing) / columns;
    final tileHeight = tileWidth;
    final top =
        (giphyTab ? 4.0 : 0.0) + (index ~/ columns) * (tileHeight + spacing);
    final bottom = top + tileHeight;
    final position = controller.position;
    const margin = 0.0;
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
    _pickerLoadGeneration++;
    selectedIndex = 0;
    _pickerLoadedCount = _pickerPageSize;
    _pickerLoadingMore = false;
    _pickerLoadQueued = false;
    _resetLibraryList();
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
        _pickerLoadedCount = _pickerPageSize;
        _pickerLoadGeneration++;
        _pickerLoadingMore = false;
        _pickerLoadQueued = false;
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
    const imports = XTypeGroup(
      label: 'Images and ZIP archives',
      extensions: ['png', 'gif', 'jpg', 'jpeg', 'webp', 'zip'],
      mimeTypes: [
        'image/png',
        'image/gif',
        'image/jpeg',
        'image/webp',
        'application/zip',
      ],
    );
    final picked = await openFiles(acceptedTypeGroups: [imports]);
    if (Platform.isAndroid) {
      var added = 0;
      for (final file in picked) {
        try {
          final extension = file.name.split('.').last.toLowerCase();
          if (extension == 'zip') {
            if (await file.length() > 100 * 1024 * 1024) {
              throw const FormatException('ZIP files must be under 100 MB');
            }
            added += await widget.store.importZipBytes(
              await file.readAsBytes(),
              folderId: selectedFolder,
            );
            continue;
          }
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
            r'\.(png|gif|jpe?g|webp|zip)$',
            caseSensitive: false,
          ).hasMatch(path),
        )
        .toList();
    if (supported.isEmpty) {
      _showError('Choose PNG, GIF, JPEG, WebP, or ZIP files.');
      return false;
    }
    try {
      final before = widget.store.items.length;
      final images = supported
          .where((path) => !path.toLowerCase().endsWith('.zip'))
          .toList();
      await widget.store.importFiles(images, folderId: selectedFolder);
      for (final path in supported.where(
        (path) => path.toLowerCase().endsWith('.zip'),
      )) {
        final file = File(path);
        if (await file.length() > 100 * 1024 * 1024) {
          throw FormatException(
            '${file.uri.pathSegments.last} exceeds the 100 MB ZIP limit',
          );
        }
        await widget.store.importZipBytes(
          await file.readAsBytes(),
          folderId: selectedFolder,
        );
      }
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
        content: const SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SetupStep(
                number: 1,
                text: 'Enable “Memlib stickers” in Android keyboard settings.',
              ),
              SizedBox(height: 14),
              _SetupStep(
                number: 2,
                text:
                    'Open a text field and switch to the Memlib keyboard. Tap a GIF or sticker to insert it. Long-press one to share it.',
              ),
            ],
          ),
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

  Future<void> _previewItem(LibraryItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: MemlibColors.canvas,
        child: Scaffold(
          backgroundColor: MemlibColors.canvas,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            actions: [
              IconButton(
                tooltip: 'Close preview',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 6,
              boundaryMargin: const EdgeInsets.all(80),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Image.file(
                widget.store.fileFor(item),
                fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: MemlibColors.textFaint,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    _resetLibraryList();
    _resetPickerList();
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
    return widget.store.items.any(
      (item) => data.itemIds.contains(item.id) && item.folderId != target,
    );
  }

  Future<void> _drop(_LibraryDrag data, String? target) async {
    try {
      if (data.folder) {
        final folder = widget.store.folders
            .where((e) => e.id == data.id)
            .firstOrNull;
        if (folder == null) return;
        await widget.store.moveFolder(folder, target);
      } else {
        final items = widget.store.items
            .where((item) => data.itemIds.contains(item.id))
            .toList();
        if (items.isEmpty) return;
        await widget.store.moveItems(items, target);
      }
      if (mounted) {
        setState(() {
          selectedItemIds.clear();
          selectionAnchorId = null;
          mobileSelecting = false;
          if (target != null) expandedFolders.add(target);
        });
      }
    } catch (e) {
      _showError('Could not move: $e');
    }
  }

  Widget _dropOn(String? target, Widget child) => DragTarget<_LibraryDrag>(
    onWillAcceptWithDetails: (details) => _canDrop(details.data, target),
    onAcceptWithDetails: (details) => _drop(details.data, target),
    builder: (context, candidates, rejects) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: candidates.isEmpty
            ? Colors.transparent
            : MemlibColors.accentSoft,
        borderRadius: BorderRadius.circular(MemlibRadius.tile),
        border: Border.all(
          color: candidates.isEmpty
              ? Colors.transparent
              : MemlibColors.accent,
          width: 1.5,
        ),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    ),
  );

  _LibraryDrag _dragDataForItem(LibraryItem item) => _LibraryDrag.items(
    selectedItemIds.contains(item.id)
        ? selectedItems.map((selected) => selected.id).toList()
        : [item.id],
  );

  Widget _dragFeedback(String label, IconData icon) => Material(
    color: MemlibColors.highest,
    elevation: 12,
    shadowColor: Colors.black,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: MemlibColors.accentLine),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: MemlibColors.accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: MemlibColors.text,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _drag(_LibraryDrag data, String label, IconData icon, Widget child) {
    final feedback = _dragFeedback(label, icon);
    if (Theme.of(context).platform == TargetPlatform.android) {
      if (!data.folder) {
        if (mobileSelecting ||
            data.itemIds.isEmpty ||
            !selectedItemIds.contains(data.itemIds.first)) {
          return child;
        }
        return LongPressDraggable<_LibraryDrag>(
          data: data,
          feedback: feedback,
          childWhenDragging: Opacity(opacity: .4, child: child),
          child: child,
        );
      }
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
              (searchController.text.trim().isNotEmpty ||
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
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
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
                    const Text(
                      'Existing tags',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: MemlibColors.textFaint,
                      ),
                    ),
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
      _resetLibraryList();
      if (picker) _resetPickerList();
    });
  }

  Widget _tagFilterButton() {
    final active = selectedTagFilters.isNotEmpty;
    return OutlinedButton.icon(
      onPressed: _showTagFilters,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        foregroundColor: active ? MemlibColors.accent : MemlibColors.text,
        backgroundColor: active ? MemlibColors.accentSoft : null,
        side: BorderSide(
          color: active ? MemlibColors.accentLine : MemlibColors.border,
        ),
      ),
      icon: const Icon(Icons.sell_outlined, size: 17),
      label: Text(
        active ? 'Tags (${selectedTagFilters.length})' : 'Tags',
      ),
    );
  }

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
    final width = box.size.width - _gridPad * 2;
    final columns = (width / (_gridExtent + _gridGap)).ceil().clamp(1, 100);
    final tileWidth = (width - (columns - 1) * _gridGap) / columns;
    final strideY = tileWidth / _gridAspect + _gridGap;
    final column = ((local.dx - _gridPad) / (tileWidth + _gridGap)).floor();
    final row = ((local.dy + position.pixels - _gridTop) / strideY).floor();
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

  Widget _toolbarButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
  }) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon),
    iconSize: 20,
    color: color ?? MemlibColors.text,
    constraints: const BoxConstraints.tightFor(width: 38, height: 38),
    padding: EdgeInsets.zero,
    onPressed: onPressed,
  );

  Widget _toolbarDivider() => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: MemlibColors.border,
  );

  Widget _selectionToolbar({required bool compact}) {
    final items = selectedItems;
    final tags = items.expand((item) => item.tags).toSet().toList()..sort();
    return Material(
      elevation: 18,
      shadowColor: Colors.black,
      color: MemlibColors.high,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: MemlibColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: MemlibColors.accentSoft,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                compact ? '${items.length}' : '${items.length} selected',
                style: const TextStyle(
                  color: MemlibColors.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 4),
            _toolbarButton(
              tooltip: 'Add tag',
              icon: Icons.sell_outlined,
              onPressed: () async {
                final tag = await _chooseTag(items.length);
                if (tag != null) await widget.store.addTagToItems(items, tag);
              },
            ),
            if (tags.isNotEmpty)
              SizedBox(
                width: 38,
                height: 38,
                child: PopupMenuButton<String>(
                  tooltip: 'Remove tags',
                  icon: const Icon(
                    Icons.label_off_outlined,
                    size: 20,
                    color: MemlibColors.text,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (tag) =>
                      widget.store.removeTagFromItems(items, tag),
                  itemBuilder: (_) => [
                    for (final tag in tags)
                      PopupMenuItem(value: tag, child: Text('Remove $tag')),
                  ],
                ),
              ),
            _toolbarButton(
              tooltip: 'Move',
              icon: Icons.drive_file_move_outline,
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
            _toolbarButton(
              tooltip: 'Delete',
              icon: Icons.delete_outline,
              color: MemlibColors.danger,
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
                        style: _dangerStyle,
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
            _toolbarDivider(),
            _toolbarButton(
              tooltip: 'Clear selection',
              icon: Icons.close,
              color: MemlibColors.textMuted,
              onPressed: _clearSelection,
            ),
          ],
        ),
      ),
    );
  }

  static final _dangerStyle = FilledButton.styleFrom(
    backgroundColor: MemlibColors.danger,
    foregroundColor: MemlibColors.onAccent,
  );

  void _switchMainTab(int tab) => _switchTab(tab == 1);

  Widget _mainNavigation() => SegmentedTabs(
    tabs: const [
      SegmentTab('Library', Icons.grid_view_rounded),
      SegmentTab('GIPHY', Icons.auto_awesome_outlined),
    ],
    selected: giphyTab ? 1 : 0,
    onChanged: _switchMainTab,
  );

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

  void _settingsAction(String action) {
    if (action == 'shortcut') unawaited(_changeShortcut());
    if (action == 'startup') unawaited(_toggleStartup());
    if (action == 'keyboard') unawaited(_showKeyboardSetup());
    if (action == 'updates') unawaited(_checkForUpdates());
    if (action == 'paste') {
      unawaited(
        AndroidBridge.importClipboardImage().catchError((Object e) {
          _showError('Could not import clipboard image: $e');
        }),
      );
    }
  }

  Future<void> _checkForUpdates({bool automatic = false}) async {
    try {
      final release = await ReleaseUpdater.checkForUpdate();
      if (!mounted) return;
      if (release == null) {
        if (!automatic) _showError('Memlib is up to date.');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Memlib ${release.versionLabel} is available'),
          content: Text(
            release.notes.trim().isEmpty
                ? 'Install the latest version from GitHub Releases?'
                : release.notes.trim(),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                unawaited(_downloadAndInstallUpdate(release));
              },
              child: const Text('Update'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      if (!automatic) _showError('Could not check for updates: $error');
      debugPrint('Memlib update check failed: $error');
    }
  }

  Future<void> _downloadAndInstallUpdate(GithubRelease release) async {
    try {
      final asset = Platform.isWindows
          ? 'MemLib-Windows.zip'
          : 'MemLib-Android.apk';
      final file = await ReleaseUpdater.download(release, asset);
      if (Platform.isWindows) {
        await ReleaseUpdater.installWindows(file);
        return;
      }
      final launched = await AndroidBridge.installApk(file);
      if (!mounted) return;
      if (!launched) {
        _showError(
          'Allow Memlib to install unknown apps in Android settings, then choose Check for updates again.',
        );
      }
    } catch (error) {
      if (mounted) _showError('Could not install the update: $error');
    }
  }

  Widget _menuRow(IconData icon, String label, {Color? color}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color ?? MemlibColors.textMuted),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color),
        ),
      ),
    ],
  );

  Widget _settingsButton() {
    final platform = Theme.of(context).platform;
    return PopupMenuButton<String>(
      tooltip: 'Settings',
      icon: const Icon(Icons.settings_outlined, size: 20),
      position: PopupMenuPosition.under,
      onSelected: _settingsAction,
      itemBuilder: (_) => [
        if (platform == TargetPlatform.windows) ...[
          PopupMenuItem(
            value: 'shortcut',
            child: _menuRow(Icons.keyboard_command_key, 'Change picker shortcut'),
          ),
          CheckedPopupMenuItem(
            value: 'startup',
            checked: startupEnabled,
            child: const Text('Launch at sign-in'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'updates',
            child: _menuRow(Icons.system_update_alt, 'Check for updates'),
          ),
        ],
        if (platform == TargetPlatform.android) ...[
          PopupMenuItem(
            value: 'keyboard',
            child: _menuRow(Icons.keyboard_outlined, 'Set up keyboard'),
          ),
          PopupMenuItem(
            value: 'paste',
            child: _menuRow(
              Icons.content_paste,
              'Import image from clipboard',
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'updates',
            child: _menuRow(Icons.system_update_alt, 'Check for updates'),
          ),
        ],
      ],
    );
  }

  Widget _accountButton() {
    final cloud = widget.cloud;
    if (cloud == null || !cloud.configured) return const SizedBox.shrink();
    if (!cloud.signedIn) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton.icon(
          onPressed: () => showDialog<bool>(
            context: context,
            builder: (_) => AccountDialog(cloud: cloud),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          icon: const Icon(Icons.person_outline, size: 18),
          label: const Text('Sign in'),
        ),
      );
    }
    final status = cloud.syncError != null
        ? 'Sync needs attention'
        : cloud.syncing
        ? 'Syncing…'
        : cloud.lastSyncedAt == null
        ? 'Waiting to sync'
        : 'Up to date';
    final statusColor = cloud.syncError != null
        ? MemlibColors.danger
        : cloud.syncing
        ? MemlibColors.accent
        : const Color(0xFF7FD6A5);
    return PopupMenuButton<String>(
      tooltip:
          cloud.syncError ?? (cloud.syncing ? 'Syncing' : 'Account and sync'),
      position: PopupMenuPosition.under,
      icon: Icon(
        cloud.syncError != null
            ? Icons.cloud_off_outlined
            : cloud.syncing
            ? Icons.sync
            : Icons.cloud_done_outlined,
        size: 20,
        color: cloud.syncError != null ? MemlibColors.danger : null,
      ),
      onSelected: (value) => unawaited(_accountAction(value)),
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cloud.email ?? 'Signed in',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: MemlibColors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status,
                    style: const TextStyle(
                      color: MemlibColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'sync', child: _menuRow(Icons.sync, 'Sync now')),
        if (cloud.guestLibraryAvailable)
          PopupMenuItem(
            value: 'import',
            child: _menuRow(Icons.move_to_inbox_outlined, 'Import local library'),
          ),
        PopupMenuItem(
          value: 'signout',
          child: _menuRow(Icons.logout, 'Sign out'),
        ),
      ],
    );
  }

  Widget _syncBanner() {
    final cloud = widget.cloud!;
    final actionStyle = TextButton.styleFrom(
      foregroundColor: MemlibColors.text,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: MemlibColors.dangerSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x55FF8F87)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: MemlibColors.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cloud.syncError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: MemlibColors.text),
            ),
          ),
          if (cloud.conflict != null) ...[
            TextButton(
              style: actionStyle,
              onPressed: () =>
                  unawaited(cloud.resolveConflict(keepDevice: false)),
              child: const Text('Use cloud'),
            ),
            TextButton(
              style: actionStyle,
              onPressed: () =>
                  unawaited(cloud.resolveConflict(keepDevice: true)),
              child: const Text('Keep device'),
            ),
          ] else
            TextButton(
              style: actionStyle,
              onPressed: () => unawaited(cloud.syncNow()),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Widget _dropOverlay() => Positioned.fill(
    child: IgnorePointer(
      child: ColoredBox(
        color: const Color(0xE60E0C13),
        child: Center(
          child: Container(
            width: 380,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 28),
            decoration: BoxDecoration(
              color: MemlibColors.accentSoft,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: MemlibColors.accentLine, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: MemlibColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.file_download_outlined,
                    size: 32,
                    color: MemlibColors.onAccent,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Drop images to import',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  selectedFolder == null
                      ? 'Into your library'
                      : 'Into ${currentFolder?.name ?? 'your library'}',
                  style: const TextStyle(color: MemlibColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720 && !picker;
    final inlineNavigation = MediaQuery.sizeOf(context).width >= 600;
    final content = picker
        ? _pickerView()
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) SizedBox(width: 232, child: _sidebar()),
              Expanded(
                child: Column(
                  children: [
                    if (widget.cloud?.syncError != null) _syncBanner(),
                    if (giphyTab)
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
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandMark(size: 26),
                  const SizedBox(width: 10),
                  const Text(
                    'Memlib',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.3,
                    ),
                  ),
                  if (inlineNavigation) ...[
                    const SizedBox(width: 24),
                    _mainNavigation(),
                  ],
                ],
              ),
              actions: [
                _accountButton(),
                if (Platform.isWindows)
                  IconButton(
                    tooltip: 'Quick picker · ${hotkey.debugName}',
                    icon: const Icon(Icons.bolt, size: 20),
                    onPressed: () => _togglePicker(),
                  ),
                _settingsButton(),
                if (!wide)
                  IconButton(
                    tooltip: 'Import files',
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 21,
                    ),
                    onPressed: _import,
                  ),
                const SizedBox(width: 8),
              ],
            ),
      bottomNavigationBar: picker || inlineNavigation
          ? null
          : DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: MemlibColors.hairline)),
              ),
              child: NavigationBar(
                selectedIndex: giphyTab ? 1 : 0,
                onDestinationSelected: _switchMainTab,
                labelBehavior:
                    NavigationDestinationLabelBehavior.alwaysShow,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.grid_view_outlined),
                    selectedIcon: Icon(Icons.grid_view_rounded),
                    label: 'Library',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.auto_awesome_outlined),
                    selectedIcon: Icon(Icons.auto_awesome),
                    label: 'GIPHY',
                  ),
                ],
              ),
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
                  if (draggingFiles) _dropOverlay(),
                ],
              ),
            )
          : content,
    );
  }

  static const _pickerPad = 12.0;
  static const _pickerGap = 8.0;
  static const _pickerColumns = 4;
  static const _giphyPickerExtent = 145.0;

  Widget _pickerFilters() {
    final folders = widget.store.folders.toList()
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _pickerPad),
        children: [
          FilterPill(
            label: 'All',
            selected: selectedFolder == null && !favoritesOnly,
            onTap: () => setState(() {
              selectedFolder = null;
              favoritesOnly = false;
              _resetPickerList();
            }),
          ),
          const SizedBox(width: 6),
          FilterPill(
            label: 'Favourites',
            icon: Icons.star_rounded,
            selected: favoritesOnly,
            onTap: () => setState(() {
              selectedFolder = null;
              favoritesOnly = true;
              _resetPickerList();
            }),
          ),
          for (final folder in folders)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: FilterPill(
                label: folder.name,
                icon: Icons.folder_outlined,
                selected: selectedFolder == folder.id,
                onTap: () => setState(() {
                  selectedFolder = folder.id;
                  favoritesOnly = false;
                  _resetPickerList();
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pickerView() {
    final items = visibleItems;
    final folders = visibleFolders;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MemlibColors.canvas,
        border: Border.all(color: MemlibColors.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(_pickerPad, 8, 6, 8),
            child: Row(
              children: [
                const BrandMark(size: 24),
                const SizedBox(width: 12),
                SegmentedTabs(
                  tabs: const [
                    SegmentTab('Library', Icons.grid_view_rounded),
                    SegmentTab('GIPHY', Icons.auto_awesome_outlined),
                  ],
                  selected: giphyTab ? 1 : 0,
                  onChanged: (index) => _switchTab(index == 1),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Open library',
                  icon: const Icon(Icons.open_in_full, size: 17),
                  onPressed: _openLibrary,
                ),
                IconButton(
                  tooltip: 'Close popup',
                  icon: const Icon(Icons.close, size: 19),
                  onPressed: _dismissPicker,
                ),
              ],
            ),
          ),
          if (giphyTab)
            Expanded(child: _giphyView(compact: true))
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(_pickerPad, 0, _pickerPad, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      focusNode: searchFocus,
                      controller: searchController,
                      onChanged: (_) => setState(_resetPickerList),
                      style: const TextStyle(fontSize: 15),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: 'Search items and tags',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _tagFilterButton(),
                ],
              ),
            ),
            _pickerFilters(),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty && folders.isEmpty
                  ? _emptyHint(
                      Icons.search_off_rounded,
                      'No matching items',
                      'Try another search or folder.',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        pickerGridWidth = constraints.maxWidth;
                        return Stack(
                          children: [
                            GridView.builder(
                              controller: pickerScroll,
                              padding: const EdgeInsets.fromLTRB(
                                _pickerPad,
                                0,
                                _pickerPad,
                                _pickerPad,
                              ),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _pickerColumns,
                                    childAspectRatio: 1.0,
                                    crossAxisSpacing: _pickerGap,
                                    mainAxisSpacing: _pickerGap,
                                  ),
                              itemCount: folders.length + items.length,
                              itemBuilder: (context, index) {
                                if (index < folders.length) {
                                  return _folderCard(
                                    folders[index],
                                    selected: index == selectedIndex,
                                  );
                                }
                                final itemIndex = index - folders.length;
                                if (itemIndex >= _pickerLoadedCount) {
                                  _queuePickerPage(items.length);
                                  return const SizedBox.expand();
                                }
                                return _itemCard(
                                  items[itemIndex],
                                  selected: index == selectedIndex,
                                );
                              },
                            ),
                            if (_pickerLoadingMore)
                              Positioned(
                                right: 12,
                                bottom: 12,
                                child: _smallLoadingIndicator(),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: MemlibColors.surface,
              border: Border(top: BorderSide(color: MemlibColors.hairline)),
            ),
            child: Row(
              children: [
                const KeyHint(keys: ['↑', '↓', '←', '→'], label: 'Move'),
                const SizedBox(width: 16),
                KeyHint(
                  keys: const ['Enter'],
                  label: giphyTab ? 'Search or paste' : 'Paste',
                ),
                const SizedBox(width: 16),
                const KeyHint(keys: ['Esc'], label: 'Close'),
                const Spacer(),
                Text(
                  giphyTab ? 'GIPHY search' : 'Type to search',
                  style: const TextStyle(
                    fontSize: 12,
                    color: MemlibColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _folderAction(LibraryFolder folder, String action) async {
    if (action == 'new') {
      final name = await _askName('New subfolder');
      if (name == null) return;
      await widget.store.addFolder(name, parentId: folder.id);
      if (mounted) setState(() => expandedFolders.add(folder.id));
    } else if (action == 'rename') {
      final name = await _askName('Rename folder', initial: folder.name);
      if (name != null) await widget.store.renameFolder(folder, name);
    } else if (action == 'delete') {
      final parent = widget.store.folders
          .where((entry) => entry.id == folder.parentId)
          .firstOrNull;
      final destination = parent?.name ?? 'All items';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove ${folder.name}?'),
          content: Text('Items and subfolders will move to $destination.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: _dangerStyle,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove folder'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (selectedFolder == folder.id) _openFolder(folder.parentId);
      await widget.store.deleteFolder(folder);
      if (mounted) setState(() => expandedFolders.remove(folder.id));
    }
  }

  Widget _folderMenu(LibraryFolder folder) => SizedBox(
    width: 28,
    height: 28,
    child: PopupMenuButton<String>(
      tooltip: 'Folder options',
      icon: const Icon(
        Icons.more_horiz,
        size: 18,
        color: MemlibColors.textMuted,
      ),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (action) => unawaited(_folderAction(folder, action)),
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: 'new',
          child: _menuRow(Icons.create_new_folder_outlined, 'New subfolder'),
        ),
        PopupMenuItem(
          value: 'rename',
          child: _menuRow(Icons.edit_outlined, 'Rename folder'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _menuRow(
            Icons.delete_outline,
            'Remove folder',
            color: MemlibColors.danger,
          ),
        ),
      ],
    ),
  );

  Widget _countLabel(int count) => Text(
    '$count',
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: MemlibColors.textFaint,
    ),
  );

  Widget _folderTile(LibraryFolder folder, {int depth = 0}) {
    final children = foldersIn(folder.id);
    final expanded = expandedFolders.contains(folder.id);
    final selected = selectedFolder == folder.id && !favoritesOnly;
    void toggle() => setState(() {
      if (expanded) {
        expandedFolders.remove(folder.id);
      } else {
        expandedFolders.add(folder.id);
      }
    });
    final tile = Padding(
      padding: EdgeInsets.only(left: depth * 14.0, top: 1),
      child: _dropOn(
        folder.id,
        Hoverable(
          builder: (context, hovered) => ListTile(
            key: ValueKey('sidebar-folder-${folder.id}'),
            leading: SizedBox(
              width: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: children.isEmpty
                        ? null
                        : Tooltip(
                            message: expanded
                                ? 'Collapse ${folder.name}'
                                : 'Expand ${folder.name}',
                            child: InkResponse(
                              radius: 14,
                              onTap: toggle,
                              child: AnimatedRotation(
                                turns: expanded ? .25 : 0,
                                duration: const Duration(milliseconds: 150),
                                child: const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: MemlibColors.textMuted,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    selected ? Icons.folder_rounded : Icons.folder_outlined,
                    size: 17,
                  ),
                ],
              ),
            ),
            title: Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
            selected: selected,
            onTap: () => _openFolder(folder.id),
            trailing: AnimatedOpacity(
              opacity: hovered || selected ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: _folderMenu(folder),
            ),
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

  Future<void> _newFolderFromSidebar() async {
    final name = await _askName('New folder');
    if (name != null) {
      await widget.store.addFolder(name, parentId: selectedFolder);
      if (selectedFolder != null) {
        setState(() => expandedFolders.add(selectedFolder!));
      }
    }
  }

  Widget _sidebar() {
    final favourites = widget.store.items.where((item) => item.favorite);
    final rootFolders = foldersIn(null);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: MemlibColors.surface,
        border: Border(right: BorderSide(color: MemlibColors.hairline)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: _dropOn(
                null,
                ListTile(
                  leading: const Icon(Icons.grid_view_rounded, size: 18),
                  title: const Text('All items'),
                  trailing: _countLabel(widget.store.items.length),
                  selected: selectedFolder == null && !favoritesOnly,
                  onTap: () => _openFolder(null),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ListTile(
                leading: Icon(
                  favoritesOnly
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 19,
                ),
                title: const Text('Favourites'),
                trailing: _countLabel(favourites.length),
                selected: favoritesOnly,
                onTap: () => setState(() {
                  selectedFolder = null;
                  favoritesOnly = true;
                  selectedItemIds.clear();
                  selectionAnchorId = null;
                }),
              ),
            ),
            const SizedBox(height: 18),
            SectionLabel(
              'Folders',
              trailing: IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.add, size: 18),
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                padding: EdgeInsets.zero,
                onPressed: _newFolderFromSidebar,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  if (rootFolders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        'No folders yet',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: MemlibColors.textFaint,
                        ),
                      ),
                    ),
                  for (final folder in rootFolders) _folderTile(folder),
                ],
              ),
            ),
            if (Platform.isWindows)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: MemlibColors.hairline),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.file_download_outlined,
                      size: 16,
                      color: MemlibColors.textFaint,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Drop or paste images to import',
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 12,
                          color: MemlibColors.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static const _gridPad = 20.0;
  static const _gridGap = 12.0;
  static const _gridExtent = 168.0;
  static const _gridAspect = 0.8;
  static const _gridTop = 4.0;

  List<LibraryFolder> _ancestors(LibraryFolder folder) {
    final chain = <LibraryFolder>[];
    final seen = <String>{folder.id};
    var parentId = folder.parentId;
    while (parentId != null && seen.add(parentId)) {
      final id = parentId;
      final parent = widget.store.folders
          .where((entry) => entry.id == id)
          .firstOrNull;
      if (parent == null) break;
      chain.insert(0, parent);
      parentId = parent.parentId;
    }
    return chain;
  }

  Widget _crumb(String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12.5, color: MemlibColors.textMuted),
      ),
    ),
  );

  Widget _breadcrumbs(LibraryFolder folder) {
    const separator = Padding(
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: Icon(
        Icons.chevron_right_rounded,
        size: 15,
        color: MemlibColors.textFaint,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _crumb('Library', () => _openFolder(null)),
          for (final parent in _ancestors(folder)) ...[
            separator,
            _crumb(parent.name, () => _openFolder(parent.id)),
          ],
          separator,
        ],
      ),
    );
  }

  Widget _artTile(IconData icon) => Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: MemlibColors.high,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: MemlibColors.border),
    ),
    child: Icon(icon, size: 26, color: MemlibColors.textMuted),
  );

  Widget _emptyArt() => SizedBox(
    width: 150,
    height: 96,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 8,
          top: 22,
          child: Transform.rotate(
            angle: -.22,
            child: _artTile(Icons.gif_box_outlined),
          ),
        ),
        Positioned(
          right: 8,
          top: 22,
          child: Transform.rotate(
            angle: .22,
            child: _artTile(Icons.emoji_emotions_outlined),
          ),
        ),
        Positioned(
          top: 6,
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [MemlibColors.accent, MemlibColors.accentDeep],
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x558B68FF),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.collections_bookmark_outlined,
              size: 30,
              color: MemlibColors.onAccent,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _emptyHint(IconData icon, String title, String subtitle) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                color: MemlibColors.high,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 24, color: MemlibColors.textMuted),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: MemlibColors.textFaint,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _libraryEmptyState() => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _emptyArt(),
            const SizedBox(height: 22),
            Text(
              widget.store.items.isEmpty
                  ? 'Build your collection'
                  : 'Nothing found',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                widget.store.items.isEmpty
                    ? Platform.isAndroid
                          ? 'Import GIFs and stickers, then reach them from any text field with the Memlib keyboard.'
                          : 'Import GIFs and stickers, then reach them from anywhere with the quick picker.'
                    : 'Try another search or choose a different folder.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MemlibColors.textMuted,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
              label: const Text('Import images'),
            ),
            if (Platform.isWindows)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text(
                  'Drop images here, or copy image files in Explorer and press Ctrl+V',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: MemlibColors.textFaint, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _mobileFolderPills() => SizedBox(
    height: 32,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: _gridPad),
      children: [
        _dropOn(
          null,
          FilterPill(
            label: 'All items',
            selected: selectedFolder == null && !favoritesOnly,
            onTap: () => _openFolder(null),
          ),
        ),
        const SizedBox(width: 6),
        FilterPill(
          label: 'Favourites',
          icon: Icons.star_rounded,
          selected: favoritesOnly,
          onTap: () => setState(() {
            selectedFolder = null;
            favoritesOnly = true;
            selectedItemIds.clear();
            selectionAnchorId = null;
            _resetLibraryList();
          }),
        ),
        for (final folder in foldersIn(null))
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _dropOn(
              folder.id,
              FilterPill(
                label: folder.name,
                icon: Icons.folder_outlined,
                selected: selectedFolder == folder.id,
                onTap: () => _openFolder(folder.id),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _libraryView(bool wide) {
    final loadedFolders = visibleFolders;
    final loadedItems = visibleItems;
    final searching =
        searchController.text.trim().isNotEmpty ||
        selectedTagFilters.isNotEmpty;
    final folder = searching || favoritesOnly ? null : currentFolder;
    final summary =
        '${loadedFolders.length} ${loadedFolders.length == 1 ? 'folder' : 'folders'} · ${loadedItems.length} ${loadedItems.length == 1 ? 'item' : 'items'}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_gridPad, 18, _gridPad, 0),
          child: Row(
            children: [
              if (!wide && selectedFolder != null && !favoritesOnly)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: IconButton(
                    tooltip: 'Up one folder',
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: () => _openFolder(currentFolder?.parentId),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (folder != null) _breadcrumbs(folder),
                    Text(
                      searching
                          ? 'Search results'
                          : favoritesOnly
                          ? 'Favourites'
                          : currentFolder?.name ?? 'Your library',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      style: const TextStyle(
                        color: MemlibColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (!favoritesOnly && !searching)
                IconButton(
                  tooltip: 'New folder',
                  style: IconButton.styleFrom(
                    side: const BorderSide(color: MemlibColors.border),
                    minimumSize: const Size(40, 40),
                  ),
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
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
              if (currentFolder != null && !favoritesOnly) ...[
                const SizedBox(width: 4),
                _folderMenu(currentFolder!),
              ],
              if (wide) ...[
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _import,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
                  label: const Text('Import'),
                ),
              ],
            ],
          ),
        ),
        if (!wide) ...[const SizedBox(height: 14), _mobileFolderPills()],
        Padding(
          padding: const EdgeInsets.fromLTRB(_gridPad, 14, _gridPad, 14),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  focusNode: searchFocus,
                  controller: searchController,
                  onChanged: (_) => setState(() {
                    selectedItemIds.clear();
                    selectionAnchorId = null;
                    _resetLibraryList();
                  }),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search names and tags',
                    suffixIcon: searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                              searchController.clear();
                              selectedItemIds.clear();
                              selectionAnchorId = null;
                              _resetLibraryList();
                            }),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _tagFilterButton(),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: loadedItems.isEmpty && loadedFolders.isEmpty
                    ? _libraryEmptyState()
                    : Stack(
                        children: [
                          GridView.builder(
                            key: libraryGridKey,
                            controller: libraryGridScroll,
                            padding: EdgeInsets.fromLTRB(
                              _gridPad,
                              _gridTop,
                              _gridPad,
                              selectedItemIds.isEmpty ? 24 : 96,
                            ),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: _gridExtent,
                                  childAspectRatio: _gridAspect,
                                  crossAxisSpacing: _gridGap,
                                  mainAxisSpacing: _gridGap,
                                ),
                            itemCount:
                                loadedFolders.length + loadedItems.length,
                            itemBuilder: (context, index) {
                              if (index < loadedFolders.length) {
                                return _folderCard(loadedFolders[index]);
                              }
                              final itemIndex = index - loadedFolders.length;
                              if (itemIndex >= _libraryLoadedCount) {
                                _queueLibraryPage(loadedItems.length);
                                return const SizedBox.expand();
                              }
                              final item = loadedItems[itemIndex];
                              final drag = _dragDataForItem(item);
                              return _drag(
                                drag,
                                drag.itemIds.length == 1
                                    ? item.name
                                    : '${drag.itemIds.length} items',
                                Icons.image_outlined,
                                _itemCard(item),
                              );
                            },
                          ),
                          if (_libraryLoadingMore)
                            Positioned(
                              right: 16,
                              bottom: 16,
                              child: _smallLoadingIndicator(),
                            ),
                        ],
                      ),
              ),
              if (selectedItemIds.isNotEmpty)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 18,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Center(
                      child: _selectionToolbar(
                        compact: constraints.maxWidth < 360,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _giphyBadge() => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xCC0E0C13),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'GIPHY',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: .6,
          color: MemlibColors.text,
        ),
      ),
    ),
  );

  BoxDecoration _tileDecoration({
    required bool hovered,
    required bool highlighted,
  }) => BoxDecoration(
    color: hovered ? MemlibColors.high : MemlibColors.raised,
    borderRadius: BorderRadius.circular(MemlibRadius.tile),
    border: Border.all(
      color: highlighted
          ? MemlibColors.accent
          : hovered
          ? MemlibColors.border
          : MemlibColors.hairline,
      width: highlighted ? 2 : 1,
    ),
  );

  /// A rounded media tile with an ink response clipped to its shape.
  Widget _tileSurface({
    required bool hovered,
    required bool highlighted,
    required VoidCallback? onTap,
    required List<Widget> children,
  }) => AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    decoration: _tileDecoration(hovered: hovered, highlighted: highlighted),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(MemlibRadius.tile - 1),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Stack(fit: StackFit.expand, children: children),
        ),
      ),
    ),
  );

  Widget _thumb(LibraryItem? item) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x590E0C13),
      borderRadius: BorderRadius.circular(8),
    ),
    child: item == null
        ? const SizedBox.expand()
        : Padding(
            padding: const EdgeInsets.all(4),
            child: Image.file(
              widget.store.fileFor(item),
              fit: BoxFit.contain,
              cacheWidth: 180,
              errorBuilder: (_, _, _) => const SizedBox.expand(),
            ),
          ),
  );

  Widget _folderMosaic(List<LibraryItem> previews) {
    if (previews.isEmpty) {
      return Center(
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: MemlibColors.accentSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.folder_rounded,
            size: 30,
            color: MemlibColors.accent,
          ),
        ),
      );
    }
    if (previews.length == 1) return _thumb(previews.first);
    LibraryItem? at(int index) => index < previews.length ? previews[index] : null;
    Widget line(int first) => Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _thumb(at(first))),
          const SizedBox(width: 4),
          Expanded(child: _thumb(at(first + 1))),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [line(0), const SizedBox(height: 4), line(2)],
    );
  }

  Widget _folderCard(LibraryFolder folder, {bool selected = false}) {
    final subfolders = foldersIn(folder.id).length;
    final contents =
        widget.store.items.where((item) => item.folderId == folder.id).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final details = [
      if (subfolders > 0) '$subfolders ${subfolders == 1 ? 'folder' : 'folders'}',
      '${contents.length} ${contents.length == 1 ? 'item' : 'items'}',
    ].join(' · ');
    final touch = Theme.of(context).platform == TargetPlatform.android;
    final previews = contents.take(4).toList();
    final card = _dropOn(
      folder.id,
      Hoverable(
        key: ValueKey('folder-card-${folder.id}'),
        builder: (context, hovered) {
          final surface = _tileSurface(
            hovered: hovered,
            highlighted: selected,
            onTap: () => _openFolder(folder.id),
            children: [
              Padding(
                padding: picker
                    ? const EdgeInsets.fromLTRB(8, 8, 8, 30)
                    : const EdgeInsets.all(10),
                child: _folderMosaic(previews),
              ),
              if (picker)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 7,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_rounded,
                        size: 14,
                        color: MemlibColors.accent,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xCC0E0C13),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.folder_rounded,
                        size: 13,
                        color: MemlibColors.accent,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: AnimatedOpacity(
                    opacity: hovered || touch ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Color(0xCC15121C),
                        shape: BoxShape.circle,
                      ),
                      child: _folderMenu(folder),
                    ),
                  ),
                ),
              ],
            ],
          );
          if (picker) return surface;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: surface),
              const SizedBox(height: 6),
              SizedBox(
                height: 22,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 16,
                child: Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: MemlibColors.textFaint,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return _drag(
      _LibraryDrag.folder(folder.id),
      folder.name,
      Icons.folder,
      card,
    );
  }

  Widget _favouriteAction(LibraryItem item, {double size = 28}) => TileAction(
    tooltip: item.favorite ? 'Remove favourite' : 'Add favourite',
    icon: item.favorite ? Icons.star_rounded : Icons.star_border_rounded,
    color: item.favorite ? MemlibColors.star : MemlibColors.text,
    size: size,
    onPressed: () => widget.store.updateItem(item, favorite: !item.favorite),
  );

  Widget _pickerItemTile(LibraryItem item, {required bool selected}) =>
      Hoverable(
        key: ValueKey('picker-${item.id}'),
        builder: (context, hovered) => _tileSurface(
          hovered: hovered,
          highlighted: selected,
          onTap: () => _useItem(item),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 28),
              child: Image.file(
                widget.store.fileFor(item),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: MemlibColors.textFaint,
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? MemlibColors.text : MemlibColors.textMuted,
                ),
              ),
            ),
            if (item.sourceType == 'giphy')
              Positioned(left: 6, top: 6, child: _giphyBadge()),
            Positioned(
              top: 5,
              right: 5,
              child: AnimatedOpacity(
                opacity: item.favorite || hovered || selected ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: _favouriteAction(item, size: 24),
              ),
            ),
            Positioned(
              right: 5,
              bottom: 26,
              child: AnimatedOpacity(
                opacity: hovered ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: TileAction(
                  tooltip: 'Preview ${item.name}',
                  icon: Icons.zoom_out_map,
                  size: 24,
                  onPressed: () => _previewItem(item),
                ),
              ),
            ),
          ],
        ),
      );

  Future<void> _itemAction(LibraryItem item, String action) async {
    if (action == 'rename') {
      final name = await _askName('Rename item', initial: item.name);
      if (name != null) {
        await widget.store.updateItem(item, name: name);
      }
    }
    if (action == 'favourite') {
      await widget.store.updateItem(item, favorite: !item.favorite);
    }
    if (action == 'delete') {
      await widget.store.deleteItem(item);
    }
    if (action == 'source' && item.sourcePage != null) {
      await Clipboard.setData(ClipboardData(text: item.sourcePage!));
      _showError('Source link copied');
    }
    if (action == 'share' && Platform.isAndroid) {
      await AndroidBridge.shareFile(widget.store.fileFor(item));
    }
    if (action.startsWith('move:')) {
      await widget.store.updateItem(
        item,
        move: true,
        folderId: action.substring(5).isEmpty ? null : action.substring(5),
      );
    }
  }

  Widget _itemMenu(LibraryItem item) => SizedBox(
    width: 26,
    height: 22,
    child: PopupMenuButton<String>(
      tooltip: 'Item options',
      iconSize: 18,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz, color: MemlibColors.textMuted),
      position: PopupMenuPosition.under,
      onSelected: (action) => unawaited(_itemAction(item, action)),
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem(value: 'rename', child: _menuRow(Icons.edit_outlined, 'Rename')),
        if (Platform.isAndroid)
          PopupMenuItem(
            value: 'share',
            child: _menuRow(Icons.share_outlined, 'Share to another app'),
          ),
        if (item.sourcePage != null)
          PopupMenuItem(
            value: 'source',
            child: _menuRow(Icons.link, 'Copy source link'),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'move:',
          child: _menuRow(Icons.drive_file_move_outline, 'Move to All items'),
        ),
        ...widget.store.folders.map(
          (folder) => PopupMenuItem(
            value: 'move:${folder.id}',
            child: _menuRow(Icons.folder_outlined, 'Move to ${folder.name}'),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _menuRow(
            Icons.delete_outline,
            'Delete',
            color: MemlibColors.danger,
          ),
        ),
      ],
    ),
  );

  Widget _itemCard(LibraryItem item, {bool selected = false}) {
    if (picker) return _pickerItemTile(item, selected: selected);
    final touch = Theme.of(context).platform == TargetPlatform.android;
    final checked = selectedItemIds.contains(item.id);
    final selecting = selectedItemIds.isNotEmpty;
    void open() {
      if (selectedItemIds.isNotEmpty && touch) {
        _selectLibraryItem(item, checkbox: true);
      } else if (selectedItemIds.isNotEmpty ||
          (Platform.isWindows &&
              (HardwareKeyboard.instance.isShiftPressed ||
                  HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed))) {
        _selectLibraryItem(item);
      } else {
        _useItem(item);
      }
    }

    final card = Hoverable(
      key: ValueKey('item-card-${item.id}'),
      builder: (context, hovered) {
        final controls = hovered || touch || selecting;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _tileSurface(
                hovered: hovered,
                highlighted: checked,
                onTap: open,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Image.file(
                      widget.store.fileFor(item),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image_outlined,
                        color: MemlibColors.textFaint,
                      ),
                    ),
                  ),
                  if (checked)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(color: Color(0x1ABDA7FF)),
                      ),
                    ),
                  if (item.sourceType == 'giphy')
                    Positioned(left: 8, bottom: 8, child: _giphyBadge()),
                  Positioned(
                    top: 5,
                    left: 5,
                    child: AnimatedOpacity(
                      opacity: controls || checked ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: Checkbox(
                          key: ValueKey('select-${item.id}'),
                          value: checked,
                          onChanged: (_) =>
                              _selectLibraryItem(item, checkbox: true),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: AnimatedOpacity(
                      opacity: item.favorite || controls ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: _favouriteAction(item),
                    ),
                  ),
                  if (touch && checked)
                    const Positioned(
                      left: 6,
                      bottom: 6,
                      child: IgnorePointer(
                        child: Icon(
                          Icons.drag_indicator,
                          size: 22,
                          color: MemlibColors.text,
                        ),
                      ),
                    )
                  else
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: AnimatedOpacity(
                        opacity: hovered || (touch && !selecting) ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: TileAction(
                          tooltip: 'Preview ${item.name}',
                          icon: Icons.zoom_out_map,
                          size: 26,
                          onPressed: () => _previewItem(item),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 22,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _itemMenu(item),
                ],
              ),
            ),
            SizedBox(
              height: 16,
              child: item.tags.isEmpty
                  ? null
                  : Text(
                      item.tags.map((tag) => '#$tag').join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xCCBDA7FF),
                      ),
                    ),
            ),
          ],
        );
      },
    );
    if (touch && (!checked || mobileSelecting)) {
      return GestureDetector(
        onLongPressStart: (_) => setState(() {
          mobileSelecting = true;
          selectedItemIds.add(item.id);
          selectionAnchorId = item.id;
        }),
        onLongPressMoveUpdate: (details) =>
            _selectItemAt(details.globalPosition),
        onLongPressEnd: (_) => setState(() => mobileSelecting = false),
        onLongPressCancel: () => setState(() => mobileSelecting = false),
        child: card,
      );
    }
    return card;
  }

  Widget _smallLoadingIndicator() => DecoratedBox(
    decoration: BoxDecoration(
      color: MemlibColors.high,
      shape: BoxShape.circle,
      border: Border.all(color: MemlibColors.border),
    ),
    child: const Padding(
      padding: EdgeInsets.all(7),
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );

  Widget _giphyTile(
    GiphyResult item, {
    required bool selected,
    required bool compact,
    required bool touch,
  }) {
    final saved = giphyLibrary.savedItem(item);
    final saving = savingGiphy.contains(item.id);
    return Hoverable(
      key: compact ? ValueKey('giphy-${item.id}') : null,
      builder: (context, hovered) {
        final controls = hovered || touch || selected;
        return _tileSurface(
          hovered: hovered,
          highlighted: selected,
          onTap: busy ? null : () => _useGiphy(item),
          children: [
            Image.network(
              item.previewUrl,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, loadedSynchronously) {
                if ((frame != null || loadedSynchronously) &&
                    seenGiphy.add(item.id)) {
                  unawaited(giphy.track(item, GiphyAction.load));
                }
                return child;
              },
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: MemlibColors.textFaint,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x000E0C13), Color(0xD90E0C13)],
                    ),
                  ),
                  child: Text(
                    item.title.isEmpty ? 'GIPHY' : item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (GiphyService.librarySavesEnabled) ...[
              Positioned(
                top: 6,
                left: 6,
                child: AnimatedOpacity(
                  opacity: controls || saved?.favorite == true ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: TileAction(
                    tooltip: saved?.favorite == true
                        ? 'Remove favourite'
                        : 'Add favourite',
                    icon: saved?.favorite == true
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: saved?.favorite == true
                        ? MemlibColors.star
                        : MemlibColors.text,
                    onPressed: saving || busy
                        ? null
                        : () => _saveGiphy(item, toggleFavorite: true),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: AnimatedOpacity(
                  opacity: controls || saved != null ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: TileAction(
                    tooltip: saved == null
                        ? 'Save to library'
                        : 'Saved to library',
                    icon: saved == null
                        ? Icons.download_outlined
                        : Icons.check_rounded,
                    color: saved == null
                        ? MemlibColors.text
                        : MemlibColors.accent,
                    onPressed: saving || busy || saved != null
                        ? null
                        : () => _saveGiphy(item),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _giphyView({bool compact = false}) {
    final pad = compact ? _pickerPad : _gridPad;
    final gap = compact ? _pickerGap : _gridGap;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, compact ? 0 : 18, pad, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  focusNode: giphyFocus,
                  controller: giphyController,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => giphyNavigating = false,
                  onSubmitted: (_) => _searchGiphy(),
                  style: compact ? const TextStyle(fontSize: 15) : null,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Search GIPHY',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: busy || !giphy.configured
                    ? null
                    : () => _searchGiphy(),
                child: const Text('Search'),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Row(
            children: [
              SegmentedTabs(
                tabs: const [
                  SegmentTab('GIFs', Icons.gif_outlined),
                  SegmentTab('Stickers', Icons.emoji_emotions_outlined),
                ],
                selected: stickerSearch ? 1 : 0,
                height: 32,
                onChanged: busy
                    ? null
                    : (index) {
                        setState(() => stickerSearch = index == 1);
                        if (giphyController.text.trim().isNotEmpty) {
                          _searchGiphy();
                        }
                      },
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Powered by GIPHY',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: MemlibColors.textFaint,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 2,
          child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        if (error != null)
          Container(
            margin: EdgeInsets.fromLTRB(pad, 8, pad, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: MemlibColors.dangerSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 18,
                  color: MemlibColors.danger,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(error!, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        Expanded(
          child: !giphy.configured
              ? _emptyHint(
                  Icons.key_outlined,
                  'Add a GIPHY API key to search',
                  'Search is unavailable in this build',
                )
              : results.isEmpty
              ? _emptyHint(
                  busy
                      ? Icons.hourglass_top_rounded
                      : giphyQuery.isEmpty
                      ? Icons.auto_awesome_outlined
                      : Icons.search_off_rounded,
                  busy
                      ? 'Searching GIPHY…'
                      : giphyQuery.isEmpty
                      ? 'Search for a reaction or sticker'
                      : 'No results found',
                  busy || giphyQuery.isNotEmpty
                      ? ''
                      : 'Press Enter or Search to look it up.',
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (compact) giphyPickerGridWidth = constraints.maxWidth;
                    final touch =
                        Theme.of(context).platform == TargetPlatform.android;
                    return GridView.builder(
                      controller: compact ? giphyPickerScroll : null,
                      padding: EdgeInsets.fromLTRB(pad, 4, pad, pad),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: compact
                            ? _giphyPickerExtent
                            : _gridExtent,
                        childAspectRatio: 1.0,
                        crossAxisSpacing: gap,
                        mainAxisSpacing: gap,
                      ),
                      itemCount: results.length,
                      itemBuilder: (context, index) => _giphyTile(
                        results[index],
                        selected: compact && index == selectedIndex,
                        compact: compact,
                        touch: touch,
                      ),
                    );
                  },
                ),
        ),
        if (giphyHasMore && results.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
            child: Center(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _searchGiphy(more: true),
                icon: const Icon(Icons.expand_more, size: 18),
                label: const Text('More results'),
              ),
            ),
          ),
      ],
    );
  }
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

class _SetupStep extends StatelessWidget {
  const _SetupStep({required this.number, required this.text});
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: MemlibColors.accentSoft,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$number',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: MemlibColors.accent,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(
            color: MemlibColors.textMuted,
            fontSize: 14,
            height: 1.45,
          ),
        ),
      ),
    ],
  );
}
