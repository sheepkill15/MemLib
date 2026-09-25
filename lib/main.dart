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
  runApp(MemlibApp(store: store));
}

class MemlibApp extends StatelessWidget {
  const MemlibApp({super.key, required this.store});
  final LibraryStore store;

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
    home: LibraryScreen(store: store),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store});
  final LibraryStore store;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final actions = MediaActions();
  final giphy = GiphyService();
  final searchController = TextEditingController();
  final giphyController = TextEditingController();
  String? selectedFolder;
  bool favoritesOnly = false;
  bool picker = false;
  bool giphyTab = false;
  bool stickerSearch = false;
  bool busy = false;
  String? error;
  List<GiphyResult> results = [];
  late final HotKey hotkey;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refresh);
    if (Platform.isWindows) {
      hotkey = HotKey(key: PhysicalKeyboardKey.keyV, modifiers: [HotKeyModifier.control, HotKeyModifier.alt]);
      hotKeyManager.register(hotkey, keyDownHandler: (_) => _togglePicker(fromShortcut: true)).catchError((Object e) {
        if (mounted) setState(() => error = 'Global shortcut unavailable: $e');
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) hotKeyManager.unregister(hotkey);
    widget.store.removeListener(_refresh);
    searchController.dispose();
    giphyController.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _togglePicker({bool fromShortcut = false}) async {
    if (!picker) {
      if (fromShortcut) { actions.rememberTarget(); } else { actions.previousWindow = null; }
    }
    setState(() { picker = !picker; giphyTab = false; selectedFolder = null; favoritesOnly = false; searchController.clear(); });
    if (Platform.isWindows) {
      await windowManager.setSize(picker ? const Size(620, 560) : const Size(1050, 720));
      await windowManager.show();
      await windowManager.focus();
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
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name'), onSubmitted: (_) => Navigator.pop(context, controller.text)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save'))],
    ));
    controller.dispose();
    return value;
  }

  Future<void> _useItem(LibraryItem item) async {
    try {
      await actions.copyFile(widget.store.fileFor(item));
      await widget.store.markUsed(item);
      if (picker && Platform.isWindows) {
        final pasted = await actions.pasteIntoPreviousWindow();
        if (!pasted) _showError('Copied. Press Ctrl+V in the target app.');
        setState(() => picker = false);
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
      appBar: AppBar(
        title: Text(picker ? 'Quick pick' : 'Memlib'),
        actions: [
          if (Platform.isWindows) IconButton(tooltip: picker ? 'Open library' : 'Quick picker · Ctrl+Alt+V', icon: Icon(picker ? Icons.open_in_full : Icons.bolt), onPressed: () => _togglePicker()),
          if (!picker) IconButton(tooltip: 'Import files', icon: const Icon(Icons.add_photo_alternate_outlined), onPressed: _import),
        ],
      ),
      body: Row(children: [
        if (wide) SizedBox(width: 220, child: _sidebar()),
        Expanded(child: Column(children: [
          if (!picker) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Library'), icon: Icon(Icons.collections_outlined)), ButtonSegment(value: true, label: Text('GIPHY'), icon: Icon(Icons.search))], selected: {giphyTab}, onSelectionChanged: (v) => setState(() => giphyTab = v.first))),
          if (giphyTab && !picker) Expanded(child: _giphyView()) else Expanded(child: _libraryView(wide)),
        ])),
      ]),
    );
  }

  Widget _sidebar() => Container(
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
    Padding(padding: const EdgeInsets.all(16), child: TextField(controller: searchController, onChanged: (_) => setState(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search your library', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))))),
    Expanded(child: visibleItems.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.collections_bookmark_outlined, size: 60), const SizedBox(height: 12), Text(widget.store.items.isEmpty ? 'Your collection starts here' : 'Nothing found'), const SizedBox(height: 12), if (!picker) FilledButton.icon(onPressed: _import, icon: const Icon(Icons.add), label: const Text('Import stickers or GIFs'))])) : GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: picker ? 140 : 180, childAspectRatio: 0.85, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: visibleItems.length,
      itemBuilder: (context, index) => _itemCard(visibleItems[index]),
    )),
    if (picker && Platform.isWindows) const Padding(padding: EdgeInsets.all(8), child: Text('Ctrl+Alt+V · Tap an item to paste into the previous app', style: TextStyle(color: Colors.white54, fontSize: 12))),
  ]);

  Widget _itemCard(LibraryItem item) => Card(clipBehavior: Clip.antiAlias, margin: EdgeInsets.zero, child: InkWell(
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
