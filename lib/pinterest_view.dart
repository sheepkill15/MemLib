import 'dart:async';

import 'package:flutter/material.dart';

import 'library_store.dart';
import 'link_tiles.dart';
import 'pinterest_service.dart';
import 'theme.dart';

/// Library-window hooks for board tiles: dragging onto folders and a menu.
abstract class PinterestBoardHost {
  Widget boardMenu(PinterestBoard board);
  Widget wrapBoard(PinterestBoard board, Widget tile);
}

/// Adds every pin on [board] to a library folder named after it inside
/// [parentId], reusing a folder of that name there. Returns the folder and
/// how many pins were new.
Future<(LibraryFolder, int)> addBoardToLibrary(
  PinterestService service,
  LibraryStore store,
  PinterestBoard board, {
  String? parentId,
}) async {
  final all = await service.allPins(board.id);
  // Folder names are limited to 100 characters.
  final trimmed = board.name.trim();
  final name = trimmed.isEmpty
      ? 'Pinterest board'
      : trimmed.length > 100
      ? trimmed.substring(0, 100).trim()
      : trimmed;
  var folder = store.folders
      .where(
        (folder) =>
            folder.parentId == parentId &&
            folder.name.toLowerCase() == name.toLowerCase(),
      )
      .firstOrNull;
  if (folder == null) {
    await store.addFolder(name, parentId: parentId);
    folder = store.folders.last;
  }
  final before = store.items.length;
  await store.addLinkedItems(
    all.map((pin) => pin.toLink()),
    folderId: folder.id,
  );
  return (folder, store.items.length - before);
}

/// Adds [board] with [addBoardToLibrary] and reports the outcome through
/// [onMessage]. Does nothing while the same board is already being added.
Future<void> importBoard(
  PinterestService service,
  LibraryStore store,
  PinterestBoard board, {
  String? parentId,
  required void Function(String message) onMessage,
}) async {
  if (!service.startImport(board.id)) return;
  onMessage('Adding ${board.name}…');
  try {
    final (folder, added) = await addBoardToLibrary(
      service,
      store,
      board,
      parentId: parentId,
    );
    onMessage(
      added == 0
          ? 'Every pin on ${board.name} is already in ${folder.name}'
          : 'Added $added ${added == 1 ? 'pin' : 'pins'} to ${folder.name}',
    );
  } catch (e) {
    onMessage('Could not add ${board.name}: $e');
  } finally {
    service.endImport(board.id);
  }
}

/// Browses the signed-in person's Pinterest boards live. Pins can be copied,
/// or saved to the library as links; nothing from Pinterest is stored.
///
/// Boards and pins load a page at a time as the grid scrolls, and stay in
/// memory for the session, so going back to a board does not refetch it.
class PinterestView extends StatefulWidget {
  const PinterestView({
    super.key,
    required this.service,
    required this.store,
    required this.folderId,
    required this.onUse,
    required this.onMessage,
    this.host,
    this.boardHost,
  });

  final PinterestService service;
  final LibraryStore store;

  /// The library folder that saved pins go into.
  final String? folderId;
  final Future<void> Function(PinterestPin pin) onUse;
  final void Function(String message) onMessage;

  /// Bulk selection, dragging and the item menu from the library window.
  final LinkTileHost? host;
  final PinterestBoardHost? boardHost;

  @override
  State<PinterestView> createState() => _PinterestViewState();
}

class _PinterestViewState extends State<PinterestView> {
  static const _pad = 16.0;
  static const _gap = 12.0;

  /// How close to the end of the grid the next page starts loading.
  static const _prefetchExtent = 900.0;

  PinterestBoard? board;
  bool connecting = false;
  String? error;
  final saving = <String>{};

  /// The open board's pins as links, rebuilt only when the pins change.
  List<MediaLink> _links = const [];
  PinterestFeed<PinterestPin>? _linksFeed;
  int _linksRevision = -1;

  bool get addingBoard => board != null && service.isImporting(board!.id);

  PinterestService get service => widget.service;
  PinterestFeed<PinterestPin>? get pinFeed =>
      board == null ? null : service.pinFeed(board!.id);
  PinterestFeed<Object?> get feed => pinFeed ?? service.boardFeed;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await service.load();
    if (mounted && service.configured && service.connected) {
      await service.boardFeed.ensureLoaded();
    }
  }

  void _openBoard(PinterestBoard? next) {
    setState(() {
      board = next;
      error = null;
    });
    if (next != null) unawaited(service.pinFeed(next.id).ensureLoaded());
  }

  /// Loads the next page once the grid nears its end, including when the
  /// first page does not fill the window.
  bool _onScroll(Notification notification) {
    final metrics = switch (notification) {
      ScrollNotification(:final metrics) => metrics,
      ScrollMetricsNotification(:final metrics) => metrics,
      _ => null,
    };
    if (metrics != null && metrics.extentAfter < _prefetchExtent) {
      final current = feed;
      if (current.hasMore && !current.loading && current.error == null) {
        // Notifications can arrive during layout; load outside the frame.
        Timer.run(() => unawaited(current.loadMore()));
      }
    }
    return false;
  }

  void _reload() {
    final current = feed;
    current.reset();
    unawaited(current.ensureLoaded());
  }

  Future<void> _connect() async {
    setState(() {
      connecting = true;
      error = null;
    });
    try {
      await service.connect();
      service.clearFeeds();
      await service.boardFeed.ensureLoaded();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> _disconnect() async {
    await service.disconnect();
    if (!mounted) return;
    setState(() {
      board = null;
      error = null;
    });
  }

  LibraryItem? _saved(PinterestPin pin) =>
      widget.store.itemBySource('pinterest', pin.id);

  Future<void> _save(PinterestPin pin, {bool toggleFavorite = false}) async {
    if (!saving.add(pin.id)) return;
    setState(() {});
    try {
      final existing = _saved(pin);
      if (toggleFavorite && existing != null) {
        await widget.store.updateItem(existing, favorite: !existing.favorite);
        widget.onMessage(
          existing.favorite ? 'Added to favourites' : 'Removed from favourites',
        );
      } else if (existing != null) {
        widget.onMessage('Already in your library');
      } else {
        await widget.store.addLinkedItem(
          pin.toLink(favorite: toggleFavorite),
          folderId: _validFolder,
        );
        widget.onMessage(
          toggleFavorite ? 'Added to favourites' : 'Saved to your library',
        );
      }
    } catch (e) {
      widget.onMessage('Could not save pin: $e');
    } finally {
      if (mounted) setState(() => saving.remove(pin.id));
    }
  }

  String? get _validFolder =>
      widget.store.folders.any((folder) => folder.id == widget.folderId)
      ? widget.folderId
      : null;

  /// Adds every pin on the open board to a library folder named after it.
  Future<void> _addBoard() async {
    final open = board;
    if (open == null) return;
    await importBoard(
      service,
      widget.store,
      open,
      parentId: _validFolder,
      onMessage: widget.onMessage,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      service,
      service.boardFeed,
      ?pinFeed,
    ]),
    builder: (context, _) {
      final current = feed;
      final failure = error ?? current.error?.toString();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (service.configured && service.connected) _header(),
          SizedBox(
            height: 2,
            child: current.loading || addingBoard
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
          if (failure != null)
            _errorBanner(
              failure,
              onRetry: error == null && current.error != null
                  ? () => unawaited(current.loadMore())
                  : null,
            ),
          Expanded(child: _body()),
        ],
      );
    },
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(_pad, 10, _pad, 8),
    child: Row(
      children: [
        if (board != null) ...[
          IconButton(
            tooltip: 'All boards',
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => _openBoard(null),
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                board?.name ?? 'Your boards',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                board == null
                    ? service.username == null
                          ? 'Pinterest'
                          : 'Pinterest · @${service.username}'
                    : '${board!.pinCount} pins · saved pins stay linked to Pinterest',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: MemlibColors.textFaint,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (board != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: addingBoard ? null : _addBoard,
            icon: const Icon(Icons.library_add_outlined, size: 18),
            label: const Text('Add board to library'),
          ),
        PopupMenuButton<String>(
          tooltip: 'Pinterest options',
          icon: const Icon(Icons.more_horiz, color: MemlibColors.textMuted),
          onSelected: (action) {
            if (action == 'refresh') _reload();
            if (action == 'disconnect') unawaited(_disconnect());
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'refresh',
              child: Text(board == null ? 'Refresh boards' : 'Refresh pins'),
            ),
            const PopupMenuItem(
              value: 'disconnect',
              child: Text('Disconnect Pinterest'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _errorBanner(String message, {VoidCallback? onRetry}) => Container(
    margin: const EdgeInsets.fromLTRB(_pad, 8, _pad, 0),
    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
    constraints: const BoxConstraints(minHeight: 44),
    decoration: BoxDecoration(
      color: MemlibColors.dangerSoft,
      borderRadius: BorderRadius.circular(MemlibRadius.control),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, size: 18, color: MemlibColors.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );

  Widget _hint(
    IconData icon,
    String title,
    String subtitle, {
    Widget? action,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: MemlibColors.textFaint),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: MemlibColors.textMuted),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action],
        ],
      ),
    ),
  );

  Widget _body() {
    if (!service.configured) {
      return _hint(
        Icons.key_outlined,
        'Pinterest is unavailable in this build',
        'It needs the Pinterest sign-in function to be deployed.',
      );
    }
    if (!service.connected) {
      return _hint(
        Icons.push_pin_outlined,
        'Bring in your Pinterest boards',
        'Browse your boards and save pins to Memlib. Saved pins stay linked '
            'to Pinterest and load from there.',
        action: FilledButton.icon(
          onPressed: connecting ? null : _connect,
          icon: connecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login, size: 18),
          label: Text(
            connecting ? 'Waiting for Pinterest…' : 'Connect Pinterest',
          ),
        ),
      );
    }
    final pins = pinFeed;
    if (pins == null) {
      final boards = service.boardFeed;
      if (boards.items.isEmpty) {
        return _hint(
          boards.loading
              ? Icons.hourglass_top_rounded
              : Icons.dashboard_outlined,
          boards.loading
              ? 'Loading boards…'
              : boards.error == null
              ? 'No boards yet'
              : 'Boards did not load',
          '',
        );
      }
      return _grid(
        key: const PageStorageKey('pinterest-boards'),
        itemCount: boards.items.length,
        itemBuilder: (index) => _boardTile(boards.items[index]),
      );
    }
    if (pins.items.isEmpty) {
      // Pages of only video pins come back empty; the feed skips several in
      // a row, after which the person can keep looking.
      return _hint(
        pins.loading
            ? Icons.hourglass_top_rounded
            : Icons.image_not_supported_outlined,
        pins.loading
            ? 'Loading pins…'
            : pins.hasMore
            ? 'No image pins yet'
            : 'No image pins on this board',
        '',
        action: !pins.loading && pins.hasMore && pins.error == null
            ? OutlinedButton(
                onPressed: () => unawaited(pins.loadMore()),
                child: const Text('Load more'),
              )
            : null,
      );
    }
    if (!identical(_linksFeed, pins) || _linksRevision != pins.revision) {
      _links = [for (final pin in pins.items) pin.toLink()];
      _linksFeed = pins;
      _linksRevision = pins.revision;
    }
    return _grid(
      key: PageStorageKey('pinterest-board-${board!.id}'),
      itemCount: pins.items.length,
      itemBuilder: (index) => _pinTile(pins.items[index], _links),
    );
  }

  Widget _grid({
    required Key key,
    required int itemCount,
    required Widget Function(int index) itemBuilder,
  }) => NotificationListener<Notification>(
    onNotification: _onScroll,
    child: GridView.builder(
      key: key,
      padding: const EdgeInsets.fromLTRB(_pad, 4, _pad, _pad),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: .86,
        crossAxisSpacing: _gap,
        mainAxisSpacing: _gap,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) => itemBuilder(index),
    ),
  );

  Widget _surface({
    required bool hovered,
    required VoidCallback? onTap,
    required List<Widget> children,
    bool highlighted = false,
  }) => AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    decoration: BoxDecoration(
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
    ),
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

  static Widget _brokenImage(
    BuildContext context,
    Object error,
    StackTrace? _,
  ) => const Center(
    child: Icon(Icons.broken_image_outlined, color: MemlibColors.textFaint),
  );

  Widget _caption(String text, {double right = 8}) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: IgnorePointer(
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 18, right, 7),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x000E0C13), Color(0xD90E0C13)],
          ),
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );

  Widget _boardTile(PinterestBoard board) {
    final host = widget.boardHost;
    final touch = Theme.of(context).platform == TargetPlatform.android;
    final tile = Hoverable(
      key: ValueKey('pinterest-board-${board.id}'),
      builder: (context, hovered) => _surface(
        hovered: hovered,
        onTap: () => _openBoard(board),
        children: [
          if (board.coverUrl != null)
            Image.network(
              board.coverUrl!,
              fit: BoxFit.cover,
              cacheWidth: 360,
              errorBuilder: _brokenImage,
            )
          else
            const Center(
              child: Icon(
                Icons.dashboard_outlined,
                size: 36,
                color: MemlibColors.textFaint,
              ),
            ),
          _caption(
            '${board.name}\n${board.pinCount} ${board.pinCount == 1 ? 'pin' : 'pins'}',
            right: host == null ? 8 : 36,
          ),
          if (board.secret)
            const Positioned(
              top: 8,
              right: 8,
              child: Icon(
                Icons.lock_outline,
                size: 16,
                color: MemlibColors.text,
              ),
            ),
          if (host != null)
            Positioned(
              right: 4,
              bottom: 4,
              child: IgnorePointer(
                ignoring: !hovered && !touch,
                child: AnimatedOpacity(
                  opacity: hovered || touch ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: host.boardMenu(board),
                ),
              ),
            ),
        ],
      ),
    );
    return host?.wrapBoard(board, tile) ?? tile;
  }

  Widget _pinTile(PinterestPin pin, List<MediaLink> order) {
    final saved = _saved(pin);
    final busy = saving.contains(pin.id) || addingBoard;
    final touch = Theme.of(context).platform == TargetPlatform.android;
    final link = pin.toLink();
    final host = widget.host;
    final checked = host?.isSelected(link) ?? false;
    void open() => widget.onUse(pin);
    final tile = Hoverable(
      key: ValueKey('pinterest-pin-${pin.id}'),
      builder: (context, hovered) {
        final controls = hovered || touch;
        return _surface(
          hovered: hovered,
          highlighted: checked,
          onTap: host == null ? open : () => host.tap(link, order, open),
          children: [
            Image.network(
              pin.previewUrl,
              fit: BoxFit.cover,
              cacheWidth: 360,
              errorBuilder: _brokenImage,
            ),
            if (checked)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0x1ABDA7FF)),
                ),
              ),
            _caption(pin.title, right: host == null ? 8 : 36),
            if (host != null)
              Positioned(
                top: 5,
                left: 5,
                child: LinkCheckbox(
                  host: host,
                  link: link,
                  order: order,
                  visible: controls,
                ),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IgnorePointer(
                    ignoring: !controls && saved?.favorite != true,
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
                        onPressed: busy
                            ? null
                            : () => _save(pin, toggleFavorite: true),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IgnorePointer(
                    ignoring: !controls && saved == null,
                    child: AnimatedOpacity(
                      opacity: controls || saved != null ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: TileAction(
                        tooltip: saved == null
                            ? 'Save to library'
                            : 'Saved to library',
                        icon: saved == null
                            ? Icons.add_rounded
                            : Icons.check_rounded,
                        color: saved == null
                            ? MemlibColors.text
                            : MemlibColors.accent,
                        onPressed: busy || saved != null
                            ? null
                            : () => _save(pin),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (host != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: IgnorePointer(
                  ignoring: !controls,
                  child: AnimatedOpacity(
                    opacity: controls ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: host.menu(link),
                  ),
                ),
              ),
          ],
        );
      },
    );
    return host?.wrap(link, order, tile) ?? tile;
  }
}
