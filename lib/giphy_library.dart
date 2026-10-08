import 'dart:typed_data';

import 'giphy_service.dart';
import 'library_store.dart';

/// Provider persistence is enabled only for builds with the required permission.
class GiphyLibrary {
  GiphyLibrary(
    this.store,
    this.download, {
    this.allowSaves = GiphyService.librarySavesEnabled,
  });

  final LibraryStore store;
  final Future<Uint8List> Function(GiphyResult) download;
  final bool allowSaves;

  String sourcePage(GiphyResult result) =>
      result.pageUrl ?? 'https://giphy.com/gifs/${result.id}';

  String sourceType(GiphyResult result) =>
      sourcePage(result).startsWith('https://static.klipy.com/')
      ? 'klipy'
      : 'giphy';

  String sourceId(GiphyResult result) => sourceType(result) == 'klipy'
      ? '${result.stickers ? 'sticker' : 'gif'}:${result.id}'
      : result.id;

  LibraryItem? savedItem(GiphyResult result) {
    final byId = store.itemBySource(sourceType(result), sourceId(result));
    if (byId != null) return byId;
    final page = sourcePage(result);
    for (final item in store.items) {
      if (item.sourcePage == page) {
        return item;
      }
    }
    return null;
  }

  Future<LibraryItem> save(
    GiphyResult result, {
    String? folderId,
    bool favorite = false,
    Uint8List? downloadedBytes,
  }) async {
    if (!allowSaves) {
      throw StateError('GIPHY library saving requires API permission');
    }
    final existing = savedItem(result);
    if (existing != null) {
      if (favorite && !existing.favorite) {
        await store.updateItem(existing, favorite: true);
      }
      return existing;
    }
    final bytes = downloadedBytes ?? await download(result);
    final header = bytes.length >= 6 ? String.fromCharCodes(bytes.take(6)) : '';
    if (header != 'GIF87a' && header != 'GIF89a') {
      throw const FormatException('GIPHY did not return a GIF');
    }
    return store.importBytes(
      bytes,
      name: result.title.trim().isEmpty ? 'GIPHY GIF' : result.title,
      extension: 'gif',
      kind: result.stickers ? 'sticker' : 'gif',
      folderId: folderId,
      favorite: favorite,
      sourceType: sourceType(result),
      sourceId: sourceId(result),
      sourcePage: sourcePage(result),
    );
  }

  Future<LibraryItem> toggleFavorite(
    GiphyResult result, {
    String? folderId,
    Uint8List? downloadedBytes,
  }) async {
    final desired = !(savedItem(result)?.favorite ?? false);
    return setFavorite(
      result,
      desired,
      folderId: folderId,
      downloadedBytes: downloadedBytes,
    );
  }

  Future<LibraryItem> setFavorite(
    GiphyResult result,
    bool favorite, {
    String? folderId,
    Uint8List? downloadedBytes,
  }) async {
    if (!allowSaves) {
      throw StateError('GIPHY library saving requires API permission');
    }
    final existing = savedItem(result);
    if (existing == null) {
      return save(
        result,
        folderId: folderId,
        favorite: favorite,
        downloadedBytes: downloadedBytes,
      );
    }
    if (existing.favorite != favorite) {
      await store.updateItem(existing, favorite: favorite);
    }
    return existing;
  }
}
