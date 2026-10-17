import 'giphy_service.dart';
import 'library_store.dart';

/// Saves provider results as links: the library keeps their metadata and the
/// GIF is loaded from the provider when shown or sent. Enabled only for builds
/// with the required permission.
class GiphyLibrary {
  GiphyLibrary(
    this.store, {
    this.allowSaves = GiphyService.librarySavesEnabled,
  });

  final LibraryStore store;
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
    return store.itemBySource(sourceType(result), sourceId(result)) ??
        store.itemBySourcePage(sourcePage(result));
  }

  Future<LibraryItem> save(
    GiphyResult result, {
    String? folderId,
    bool favorite = false,
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
    return store.addLinkedItem(
      link(result, favorite: favorite),
      folderId: folderId,
    );
  }

  /// The library link that saving [result] creates.
  MediaLink link(GiphyResult result, {bool favorite = false}) => MediaLink(
    name: result.title.trim().isEmpty ? 'KLIPY GIF' : result.title,
    kind: result.stickers ? 'sticker' : 'gif',
    mediaUrl: result.gifUrl,
    previewUrl: result.previewUrl.isEmpty ? null : result.previewUrl,
    favorite: favorite,
    sourceType: sourceType(result),
    sourceId: sourceId(result),
    sourcePage: sourcePage(result),
  );

  Future<LibraryItem> toggleFavorite(
    GiphyResult result, {
    String? folderId,
  }) async {
    final desired = !(savedItem(result)?.favorite ?? false);
    return setFavorite(result, desired, folderId: folderId);
  }

  Future<LibraryItem> setFavorite(
    GiphyResult result,
    bool favorite, {
    String? folderId,
  }) async {
    if (!allowSaves) {
      throw StateError('GIPHY library saving requires API permission');
    }
    final existing = savedItem(result);
    if (existing == null) {
      return save(result, folderId: folderId, favorite: favorite);
    }
    if (existing.favorite != favorite) {
      await store.updateItem(existing, favorite: favorite);
    }
    return existing;
  }
}
