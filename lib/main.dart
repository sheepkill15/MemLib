import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'giphy_service.dart';
import 'library_store.dart';
import 'media_actions.dart';
import 'picker_navigation.dart';
import 'shortcut_settings.dart';
import 'windows_tray.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: String.fromEnvironment('NEXT_PUBLIC_SUPABASE_URL'));
const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: String.fromEnvironment('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY'));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty) {
    await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(1050, 720), minimumSize: Size(600, 500), title: 'Memlib'),
      () async => windowManager.show(),
    );
  }
  final store = LibraryStore();
  await store.load();
  final shortcut = Platform.isWindows ? await ShortcutSettings.load() : null;
  runApp(MemlibApp(store: store, initialShortcut: shortcut));
}

class MemlibApp extends StatelessWidget {
  const MemlibApp({super.key, required this.store, this.enableTray = true, this.initialShortcut});
  final LibraryStore store;
  final bool enableTray;
  final HotKey? initialShortcut;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Memlib',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C5CDE), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF14121B),
      cardTheme: const CardThemeData(color: Color(0xFF24202E)),
    ),
    home: LibraryScreen(store: store, enableTray: enableTray, initialShortcut: initialShortcut),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store, this.enableTray = true, this.initialShortcut});
  final LibraryStore store;
  final bool enableTray;
  final HotKey? initialShortcut;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WindowListener {
  final actions = MediaActions();
  final giphy = GiphyService();
  final searchController = TextEditingController();
  final giphyController = TextEditingController();
  final searchFocus = FocusNode();
  String? selectedFolder;
  bool favoritesOnly = false;
  bool picker = false;
  bool giphyTab = false;
  bool stickerSearch = false;
  bool busy = false;
  bool windowTransition = false;
  bool pasting = false;
  int selectedIndex = 0;
  String? error;
  List<GiphyResult> results = [];
  late HotKey hotkey;
  WindowsTray? windowsTray;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refresh);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      HardwareKeyboard.instance.addHandler(_handlePickerKey);
      hotkey = widget.initialShortcut ?? ShortcutSettings.defaultShortcut();
      hotKeyManager.register(hotkey, keyDownHandler: (_) => _togglePicker(fromShortcut: true)).catchError((Object e) {
        if (mounted) setState(() => error = 'Global shortcut unavailable: $e');
      });
      if (widget.enableTray) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          try {
            windowsTray = WindowsTray();
            final ready = windowsTray!.initialize(
              openLibrary: () { if (mounted) unawaited(_openLibrary()); },
              openPicker: () { if (mounted && !picker) unawaited(_togglePicker()); },
              exitApp: () { if (mounted) unawaited(windowManager.close()); },
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
    if (Platform.isWindows) {
      hotKeyManager.unregister(hotkey);
      windowsTray?.dispose();
      HardwareKeyboard.instance.removeHandler(_handlePickerKey);
      windowManager.removeListener(this);
    }
    widget.store.removeListener(_refresh);
    searchController.dispose();
    giphyController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  void onWindowBlur() {
    if (picker && !windowTransition && !pasting) unawaited(_dismissPicker());
  }

  bool _handlePickerKey(KeyEvent event) {
    if (!picker || windowTransition || pasting || event is! KeyDownEvent) return false;
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
      _selectPickerIndex(movePickerSelection(selectedIndex, visibleItems.length, 4, direction));
      return true;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final items = visibleItems;
      if (items.isNotEmpty) unawaited(_useItem(items[selectedIndex.clamp(0, items.length - 1)]));
      return true;
    }
    return false;
  }

  void _selectPickerIndex(int index) {
    setState(() => selectedIndex = index);
    if (index < 0 || index >= visibleItems.length) return;
    final id = visibleItems[index].id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !picker) return;
      final card = GlobalObjectKey('picker-$id').currentContext;
      if (card != null) Scrollable.ensureVisible(card, duration: const Duration(milliseconds: 110), alignment: 0.2);
    });
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
      if (actions.previousWindow == await windowManager.getId()) actions.clearTarget();
    } else {
      actions.clearTarget();
    }
    windowTransition = true;
    try {
      await windowManager.hide();
      searchController.clear();
      setState(() { picker = true; giphyTab = false; selectedFolder = null; favoritesOnly = false; selectedIndex = 0; });
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(620, 540));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && picker) searchFocus.requestFocus(); });
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
    final candidate = await showDialog<HotKey>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Quick picker shortcut'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Current: ${hotkey.debugName}'),
          const SizedBox(height: 16),
          const Text('Press a new key combination:'),
          const SizedBox(height: 8),
          HotKeyRecorder(onHotKeyRecorded: (value) => update(() => recorded = value)),
          const SizedBox(height: 12),
          const Text('Use Ctrl, Alt, or the Windows key with another key.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: recorded != null && ShortcutSettings.isUsable(recorded!)
              ? () => Navigator.pop(context, recorded) : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ));
    if (candidate == null || !mounted) return;
    final sameKey = candidate.physicalKey == hotkey.physicalKey &&
      (candidate.modifiers ?? []).toSet().containsAll(hotkey.modifiers ?? []) &&
      (candidate.modifiers ?? []).length == (hotkey.modifiers ?? []).length;
    if (sameKey) return;
    try {
      await hotKeyManager.register(candidate, keyDownHandler: (_) => _togglePicker(fromShortcut: true));
      await ShortcutSettings.save(candidate);
      await hotKeyManager.unregister(hotkey);
      if (mounted) setState(() => hotkey = candidate);
    } catch (e) {
      await hotKeyManager.unregister(candidate).catchError((_) {});
      _showError('Shortcut unavailable: $e');
    }
  }

  Future<void> _import() async {
    const images = XTypeGroup(label: 'Images', extensions: ['png', 'gif', 'jpg', 'jpeg', 'webp'], mimeTypes: ['image/png', 'image/gif', 'image/jpeg', 'image/webp']);
    final picked = await openFiles(acceptedTypeGroups: [images]);
    if (picked.isEmpty) return;
    try {
      await widget.store.importFiles(picked.map((e) => e.path).toList(), folderId: selectedFolder);
    } catch (e) { _showError('Import failed: $e'); }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    return showDialog<String>(context: context, builder: (_) => _NameDialog(title: title, initial: initial));
  }

  Future<void> _useItem(LibraryItem item) async {
    try {
      await actions.copyFile(widget.store.fileFor(item));
      await widget.store.markUsed(item);
      if (picker && Platform.isWindows) {
        if (actions.previousWindow != null) {
          pasting = true;
          try {
            final pasted = await actions.pasteIntoPreviousWindow();
            if (pasted) {
              setState(() => picker = false);
              actions.clearTarget();
              await _restoreLibraryWindow();
            } else {
              await windowManager.show();
              await windowManager.focus();
              _showError('Copied. Automatic paste did not work; press Ctrl+V in the target app.');
            }
          } finally {
            pasting = false;
          }
        } else {
          await _openLibrary();
          _showError('Copied to clipboard');
        }
      } else {
        _showError('Copied to clipboard');
      }
    } catch (e) { _showError('Could not copy: $e'); }
  }

  Future<void> _searchGiphy() async {
    if (!giphy.configured) return;
    setState(() { busy = true; error = null; });
    try {
      final found = await giphy.search(giphyController.text, stickers: stickerSearch);
      if (mounted) setState(() => results = found);
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _useGiphy(GiphyResult item) async {
    try {
      setState(() => busy = true);
      final bytes = await giphy.fetchForShare(item);
      await actions.copyBytes(bytes, 'gif');
      _showError('GIF copied to clipboard');
    } catch (e) { _showError('Could not copy GIF: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  List<LibraryItem> get visibleItems {
    final query = searchController.text.trim().toLowerCase();
    final items = widget.store.items.where((item) =>
      (selectedFolder == null || item.folderId == selectedFolder) &&
      (!favoritesOnly || item.favorite) &&
      (query.isEmpty || item.name.toLowerCase().contains(query))).toList();
    items.sort((a, b) {
      if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
      return b.useCount.compareTo(a.useCount);
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720 && !picker;
    return Scaffold(
      appBar: picker ? null : AppBar(
        title: Text(picker ? 'Quick pick' : 'Memlib'),
        actions: [
          if (Platform.isWindows) IconButton(tooltip: picker ? 'Open library' : 'Quick picker · ${hotkey.debugName}', icon: Icon(picker ? Icons.open_in_full : Icons.bolt), onPressed: () => _togglePicker()),
          if (Platform.isWindows && !picker) IconButton(tooltip: 'Change quick picker shortcut', icon: const Icon(Icons.keyboard_outlined), onPressed: _changeShortcut),
          if (!picker) IconButton(tooltip: 'Import files', icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _import),
        ],
      ),
      body: picker ? _pickerView() : Row(children: [
        if (wide) SizedBox(width: 220, child: _sidebar()),
        Expanded(child: Column(children: [
          if (!picker) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Library'), icon: Icon(Icons.collections_outlined)), ButtonSegment(value: true, label: Text('GIPHY'), icon: Icon(Icons.search))], selected: {giphyTab}, onSelectionChanged: (v) => setState(() => giphyTab = v.first))),
          if (giphyTab && !picker) Expanded(child: _giphyView()) else Expanded(child: _libraryView(wide)),
        ])),
      ]),
    );
  }

  Widget _pickerView() {
    final items = visibleItems;
    return DecoratedBox(
      decoration: BoxDecoration(color: const Color(0xFF1A1623), border: Border.all(color: const Color(0xFF514462))),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 8, 2), child: Row(children: [
          const Icon(Icons.bolt, color: Color(0xFFBDA7FF), size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Memlib', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Open library', icon: const Icon(Icons.open_in_full, size: 18), onPressed: _openLibrary),
          IconButton(tooltip: 'Close popup', icon: const Icon(Icons.close, size: 18), onPressed: _dismissPicker),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(14, 2, 14, 10), child: TextField(
          focusNode: searchFocus,
          controller: searchController,
          onChanged: (_) => setState(() => selectedIndex = 0),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search), hintText: 'Find a sticker or GIF',
            isDense: true, filled: true, fillColor: const Color(0xFF2A2435),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        )),
        SizedBox(height: 42, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
          ChoiceChip(label: const Text('All'), selected: selectedFolder == null && !favoritesOnly, onSelected: (_) => setState(() { selectedFolder = null; favoritesOnly = false; selectedIndex = 0; })),
          const SizedBox(width: 7),
          ChoiceChip(label: const Text('★ Favourites'), selected: favoritesOnly, onSelected: (_) => setState(() { selectedFolder = null; favoritesOnly = true; selectedIndex = 0; })),
          ...widget.store.folders.map((folder) => Padding(padding: const EdgeInsets.only(left: 7), child: ChoiceChip(label: Text(folder.name), selected: selectedFolder == folder.id, onSelected: (_) => setState(() { selectedFolder = folder.id; favoritesOnly = false; selectedIndex = 0; })))),
        ])),
        const SizedBox(height: 8),
        Expanded(child: items.isEmpty
          ? const Center(child: Text('No matching items', style: TextStyle(color: Colors.white60)))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 1.0, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: items.length,
              itemBuilder: (context, index) => _itemCard(items[index], selected: index == selectedIndex),
            )),
        const Divider(height: 1),
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Type to search   ·   Arrow keys to move   ·   Enter to paste   ·   Esc to close', style: TextStyle(fontSize: 11, color: Colors.white54))),
      ]),
    );
  }

  Widget _sidebar() => Material(
    color: const Color(0xFF1C1924),
    child: Column(children: [
      ListTile(leading: const Icon(Icons.grid_view), title: const Text('All items'), selected: selectedFolder == null && !favoritesOnly, onTap: () => setState(() { selectedFolder = null; favoritesOnly = false; })),
      ListTile(leading: const Icon(Icons.star_outline), title: const Text('Favourites'), selected: favoritesOnly, onTap: () => setState(() { selectedFolder = null; favoritesOnly = true; })),
      const Divider(),
      Padding(padding: const EdgeInsets.only(left: 16, right: 4), child: Row(children: [const Expanded(child: Text('FOLDERS')), IconButton(tooltip: 'New folder', icon: const Icon(Icons.add), onPressed: () async { final name = await _askName('New folder'); if (name != null) await widget.store.addFolder(name); })])),
      Expanded(child: ListView(children: widget.store.folders.map((folder) => ListTile(
        leading: const Icon(Icons.folder_outlined), title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis), selected: selectedFolder == folder.id,
        onTap: () => setState(() { selectedFolder = folder.id; favoritesOnly = false; }),
        trailing: PopupMenuButton<String>(onSelected: (action) async {
          if (action == 'rename') { final name = await _askName('Rename folder', initial: folder.name); if (name != null) await widget.store.renameFolder(folder, name); }
          if (action == 'delete') await widget.store.deleteFolder(folder);
        }, itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'delete', child: Text('Remove folder; keep items'))]),
      )).toList())),
    ]),
  );

  Widget _libraryView(bool wide) => Column(children: [
    if (!wide) SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
      ChoiceChip(label: const Text('All'), selected: selectedFolder == null && !favoritesOnly, onSelected: (_) => setState(() { selectedFolder = null; favoritesOnly = false; })),
      const SizedBox(width: 8), ChoiceChip(label: const Text('★ Favourites'), selected: favoritesOnly, onSelected: (_) => setState(() { selectedFolder = null; favoritesOnly = true; })),
      ...widget.store.folders.map((folder) => Padding(padding: const EdgeInsets.only(left: 8), child: ChoiceChip(label: Text(folder.name), selected: selectedFolder == folder.id, onSelected: (_) => setState(() { selectedFolder = folder.id; favoritesOnly = false; })))),
      if (!picker) IconButton(tooltip: 'New folder', onPressed: () async { final name = await _askName('New folder'); if (name != null) await widget.store.addFolder(name); }, icon: const Icon(Icons.create_new_folder_outlined)),
    ])),
    Padding(padding: const EdgeInsets.all(16), child: TextField(focusNode: searchFocus, controller: searchController, onChanged: (_) => setState(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search your library', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))))),
    Expanded(child: visibleItems.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.collections_bookmark_outlined, size: 60), const SizedBox(height: 12), Text(widget.store.items.isEmpty ? 'Your collection starts here' : 'Nothing found'), const SizedBox(height: 12), if (!picker) FilledButton.icon(onPressed: _import, icon: const Icon(Icons.add), label: const Text('Import stickers or GIFs'))])) : GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: picker ? 140 : 180, childAspectRatio: 0.85, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: visibleItems.length,
      itemBuilder: (context, index) => _itemCard(visibleItems[index]),
    )),
    if (picker && Platform.isWindows) const Padding(padding: EdgeInsets.all(8), child: Text('Ctrl+Alt+V · Tap an item to paste into the previous app', style: TextStyle(color: Colors.white54, fontSize: 12))),
  ]);

  Widget _itemCard(LibraryItem item, {bool selected = false}) => Card(key: picker ? GlobalObjectKey('picker-${item.id}') : null, clipBehavior: Clip.antiAlias, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? const Color(0xFFBDA7FF) : Colors.transparent, width: selected ? 2 : 0)), child: InkWell(
    onTap: () => _useItem(item),
    child: Column(children: [
      Expanded(child: Stack(fit: StackFit.expand, children: [
        Padding(padding: const EdgeInsets.all(8), child: Image.file(widget.store.fileFor(item), fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined))),
        Positioned(top: 2, right: 2, child: IconButton.filledTonal(tooltip: item.favorite ? 'Remove favourite' : 'Add favourite', iconSize: 18, icon: Icon(item.favorite ? Icons.star : Icons.star_border), onPressed: () => widget.store.updateItem(item, favorite: !item.favorite))),
      ])),
      Padding(padding: const EdgeInsets.only(left: 10), child: Row(children: [Expanded(child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis)), if (!picker) PopupMenuButton<String>(tooltip: 'Item options', onSelected: (action) async {
        if (action == 'rename') { final name = await _askName('Rename item', initial: item.name); if (name != null) await widget.store.updateItem(item, name: name); }
        if (action == 'delete') await widget.store.deleteItem(item);
        if (action.startsWith('move:')) await widget.store.updateItem(item, move: true, folderId: action.substring(5).isEmpty ? null : action.substring(5));
      }, itemBuilder: (_) => [const PopupMenuItem(value: 'rename', child: Text('Rename')), const PopupMenuItem(value: 'move:', child: Text('Move to All items')), ...widget.store.folders.map((folder) => PopupMenuItem(value: 'move:${folder.id}', child: Text('Move to ${folder.name}'))), const PopupMenuItem(value: 'delete', child: Text('Delete'))])])),
    ]),
  ));

  Widget _giphyView() => Column(children: [
    Padding(padding: const EdgeInsets.all(16), child: Row(children: [Expanded(child: TextField(controller: giphyController, onSubmitted: (_) => _searchGiphy(), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search GIFs and stickers', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))))), const SizedBox(width: 8), FilledButton(onPressed: busy || !giphy.configured ? null : _searchGiphy, child: const Text('Search'))])),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [ChoiceChip(label: const Text('GIFs'), selected: !stickerSearch, onSelected: (_) => setState(() => stickerSearch = false)), const SizedBox(width: 8), ChoiceChip(label: const Text('Stickers'), selected: stickerSearch, onSelected: (_) => setState(() => stickerSearch = true)), const Spacer(), const Text('Powered by GIPHY', style: TextStyle(fontSize: 12))])),
    if (busy) const LinearProgressIndicator(),
    if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
    Expanded(child: !giphy.configured ? const Center(child: Text('Add a GIPHY API key to enable search. See README.md.')) : results.isEmpty ? const Center(child: Text('Search GIPHY to find a GIF or sticker')) : GridView.builder(
      padding: const EdgeInsets.all(16), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 1, crossAxisSpacing: 12, mainAxisSpacing: 12), itemCount: results.length,
      itemBuilder: (context, index) { final item = results[index]; return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: busy ? null : () => _useGiphy(item), child: Image.network(item.previewUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)))); },
    )),
  ]);
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
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
    ],
  );
}
