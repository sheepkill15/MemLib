import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library_store.dart';
import 'openverse_service.dart';

class OpenversePanel extends StatefulWidget {
  const OpenversePanel({super.key, required this.store, this.folderId, this.searchService});
  final LibraryStore store;
  final String? folderId;
  final OpenverseService? searchService;

  @override
  State<OpenversePanel> createState() => _OpenversePanelState();
}

class _OpenversePanelState extends State<OpenversePanel> {
  late final OpenverseService service = widget.searchService ?? OpenverseService();
  final searchController = TextEditingController();
  final saving = <String>{};
  List<OpenverseResult> results = [];
  bool stickers = false;
  bool searching = false;
  bool hasMore = false;
  int page = 0;
  String query = '';
  String? error;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refresh);
  }

  @override
  void didUpdateWidget(OpenversePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_refresh);
      widget.store.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    searchController.dispose();
    if (widget.searchService == null) service.dispose();
    super.dispose();
  }

  void _refresh() { if (mounted) setState(() {}); }

  Future<void> _search({bool more = false}) async {
    if (searching) return;
    final nextQuery = more ? query : searchController.text.trim();
    if (nextQuery.isEmpty) return;
    final nextPage = more ? page + 1 : 1;
    setState(() { searching = true; error = null; if (!more) { results = []; hasMore = false; } });
    try {
      final response = await service.search(nextQuery, stickers: stickers, page: nextPage);
      if (!mounted) return;
      setState(() { query = nextQuery; page = nextPage; results = [...results, ...response.results]; hasMore = response.hasMore; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => searching = false); }
  }

  LibraryItem? _saved(OpenverseResult result) => widget.store.items.where((item) => item.sourcePage == result.sourcePage).firstOrNull;

  Future<void> _save(OpenverseResult result, {bool favorite = false}) async {
    if (saving.contains(result.id)) return;
    final existing = _saved(result);
    if (existing != null) {
      if (favorite && !existing.favorite) await widget.store.updateItem(existing, favorite: true);
      _notice(favorite ? 'Added to favourites.' : 'Already in your library.');
      return;
    }
    setState(() => saving.add(result.id));
    try {
      final download = await service.download(result);
      await widget.store.importBytes(download.bytes, name: result.title.length > 200 ? result.title.substring(0, 200) : result.title, extension: download.extension, folderId: widget.folderId, sourcePage: result.sourcePage, licenseLabel: result.licenseLabel, favorite: favorite);
      _notice(favorite ? 'Saved to your library and favourites.' : 'Saved to your library.');
    } catch (e) { _notice('Could not save image: $e'); }
    finally { if (mounted) setState(() => saving.remove(result.id)); }
  }

  void _notice(String message) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }

  @override
  Widget build(BuildContext context) => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: Row(children: [
      Expanded(child: TextField(controller: searchController, textInputAction: TextInputAction.search, onSubmitted: (_) => _search(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search saveable GIFs and stickers'))),
      const SizedBox(width: 8),
      FilledButton(onPressed: searching ? null : () => _search(), child: const Text('Search')),
    ])),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
      ChoiceChip(label: const Text('GIFs'), selected: !stickers, onSelected: searching ? null : (_) { setState(() => stickers = false); if (searchController.text.trim().isNotEmpty) unawaited(_search()); }),
      const SizedBox(width: 8),
      ChoiceChip(label: const Text('Stickers'), selected: stickers, onSelected: searching ? null : (_) { setState(() => stickers = true); if (searchController.text.trim().isNotEmpty) unawaited(_search()); }),
      const Spacer(),
      const Text('Openverse · CC0 / public domain', style: TextStyle(color: Colors.white60, fontSize: 12)),
    ])),
    const SizedBox(height: 8),
    if (searching) const LinearProgressIndicator(minHeight: 2),
    if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: Colors.redAccent))),
    Expanded(child: results.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(searching ? 'Searching Openverse…' : query.isEmpty ? 'Find openly licensed GIFs and stickers to save, sync and favourite.' : 'No results. Try another search.', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60))))
      : GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 210, childAspectRatio: 0.78, crossAxisSpacing: 12, mainAxisSpacing: 12),
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            final saved = _saved(result);
            final isSaving = saving.contains(result.id);
            return Card(clipBehavior: Clip.antiAlias, margin: EdgeInsets.zero, child: Column(children: [
              Expanded(child: Image.network(result.previewUrl, width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined)))),
              Padding(padding: const EdgeInsets.fromLTRB(8, 5, 8, 0), child: Align(alignment: Alignment.centerLeft, child: Text(result.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))),
              Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: Row(children: [
                IconButton(tooltip: 'Copy source link · ${result.licenseLabel}', icon: const Icon(Icons.info_outline, size: 19), onPressed: () async { await Clipboard.setData(ClipboardData(text: result.sourcePage)); _notice('Source link copied.'); }),
                const Spacer(),
                IconButton(tooltip: saved?.favorite == true ? 'Already a favourite' : 'Save as favourite', icon: Icon(saved?.favorite == true ? Icons.star : Icons.star_border, size: 21), onPressed: isSaving || saved?.favorite == true ? null : () => _save(result, favorite: true)),
                IconButton(tooltip: saved == null ? 'Save to library' : 'Already saved', icon: Icon(saved == null ? Icons.download_outlined : Icons.check_circle_outline, size: 21), onPressed: isSaving || saved != null ? null : () => _save(result)),
              ])),
            ]));
          },
        )),
    if (hasMore && results.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: TextButton.icon(onPressed: searching ? null : () => _search(more: true), icon: const Icon(Icons.expand_more), label: const Text('More results'))),
  ]);
}
