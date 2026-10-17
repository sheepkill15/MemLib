import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/giphy_library.dart';
import 'package:memlib/giphy_service.dart';
import 'package:memlib/library_store.dart';

void main() {
  late Directory sandbox;
  late LibraryStore store;
  const result = GiphyResult(
    id: 'abc',
    title: 'Wave',
    previewUrl: 'https://example.org/preview.gif',
    gifUrl: 'https://example.org/wave.gif',
    pageUrl: 'https://giphy.com/gifs/wave-abc',
  );

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('memlib-giphy-test-');
    store = LibraryStore();
    store.root = sandbox;
    store.media = Directory('${sandbox.path}${Platform.pathSeparator}media');
    await store.media.create();
  });

  tearDown(() async {
    store.dispose();
    await sandbox.delete(recursive: true);
  });

  test('saving keeps only a link to the provider media', () async {
    await store.addFolder('Reactions');
    final folderId = store.folders.single.id;
    final library = GiphyLibrary(store, allowSaves: true);
    final saved = await library.save(result, folderId: folderId);
    expect(saved.isLinked, isTrue);
    expect(saved.filename, isNull);
    expect(saved.mediaUrl, result.gifUrl);
    expect(saved.previewUrl, result.previewUrl);
    expect(saved.folderId, folderId);
    expect(saved.sourcePage, result.pageUrl);
    expect(saved.sourceType, 'giphy');
    expect(saved.sourceId, 'abc');
    expect(await store.media.list().isEmpty, isTrue);
    expect(() => store.fileFor(saved), throwsStateError);
  });

  test('saving and starring the same result keeps one synced item', () async {
    final library = GiphyLibrary(store, allowSaves: true);
    final saved = await library.save(result);
    expect(saved.favorite, isFalse);

    final starred = await library.toggleFavorite(result);
    expect(starred.id, saved.id);
    expect(starred.favorite, isTrue);
    expect(store.items, hasLength(1));
    expect(store.dirtyItems, contains(saved.id));

    await library.toggleFavorite(result);
    expect(saved.favorite, isFalse);
  });

  test(
    'KLIPY GIF and sticker saves keep separate provider identities',
    () async {
      final library = GiphyLibrary(store, allowSaves: true);
      const gif = GiphyResult(
        id: 'wave',
        title: 'Wave',
        previewUrl: 'https://static.klipy.com/preview.gif',
        gifUrl: 'https://static.klipy.com/full.gif',
        pageUrl: 'https://static.klipy.com/full.gif',
      );
      const sticker = GiphyResult(
        id: 'wave',
        title: 'Wave sticker',
        previewUrl: 'https://static.klipy.com/sticker-preview.gif',
        gifUrl: 'https://static.klipy.com/sticker.gif',
        pageUrl: 'https://static.klipy.com/sticker.gif',
        stickers: true,
      );
      final savedGif = await library.save(gif);
      final savedSticker = await library.save(sticker);
      expect(savedGif.sourceType, 'klipy');
      expect(savedGif.sourceId, 'gif:wave');
      expect(savedSticker.sourceId, 'sticker:wave');
      expect(savedSticker.kind, 'sticker');
      expect(savedSticker.mediaUrl, sticker.gifUrl);
      expect(store.items, hasLength(2));
    },
  );

  test('saving is blocked until the permission flag is enabled', () async {
    final library = GiphyLibrary(store, allowSaves: false);
    await expectLater(library.save(result), throwsStateError);
    expect(store.items, isEmpty);
  });

  test('replaying a queued favourite request is idempotent', () async {
    final library = GiphyLibrary(store, allowSaves: true);
    final first = await library.setFavorite(result, true);
    final replayed = await library.setFavorite(result, true);
    expect(replayed.id, first.id);
    expect(replayed.favorite, isTrue);
    expect(store.items, hasLength(1));

    await library.setFavorite(result, false);
    await library.setFavorite(result, false);
    expect(replayed.favorite, isFalse);
  });

  test(
    'the provider ID deduplicates even when the GIPHY page changes',
    () async {
      final library = GiphyLibrary(store, allowSaves: true);
      final first = await library.save(result);
      const renamedPage = GiphyResult(
        id: 'abc',
        title: 'New title',
        previewUrl: 'https://example.org/preview.gif',
        gifUrl: 'https://example.org/wave.gif',
        pageUrl: 'https://giphy.com/gifs/renamed-abc',
      );
      final second = await library.save(renamedPage);
      expect(second.id, first.id);
      expect(store.items, hasLength(1));
    },
  );

  test('links must use HTTPS', () async {
    final library = GiphyLibrary(store, allowSaves: true);
    const insecure = GiphyResult(
      id: 'plain',
      title: 'Plain',
      previewUrl: 'http://example.org/preview.gif',
      gifUrl: 'http://example.org/wave.gif',
      pageUrl: 'https://giphy.com/gifs/plain',
    );
    await expectLater(library.save(insecure), throwsArgumentError);
    expect(store.items, isEmpty);
  });

  test('linked items survive a reload of the library index', () async {
    final library = GiphyLibrary(store, allowSaves: true);
    final saved = await library.save(result);
    final reloaded = LibraryItem.fromJson(saved.toJson());
    expect(reloaded.isLinked, isTrue);
    expect(reloaded.mediaUrl, result.gifUrl);
    expect(reloaded.previewUrl, result.previewUrl);
  });

  test('linked names are capped to the synced title limit', () async {
    final library = GiphyLibrary(store, allowSaves: true);
    final saved = await library.save(
      GiphyResult(
        id: 'long',
        title: 'x' * 300,
        previewUrl: 'https://example.org/p.gif',
        gifUrl: 'https://example.org/l.gif',
        pageUrl: 'https://giphy.com/gifs/long',
      ),
    );
    expect(saved.name, hasLength(200));
  });

  test('source lookups follow items added after an earlier lookup', () async {
    expect(store.itemBySource('giphy', 'abc'), isNull);
    final library = GiphyLibrary(store, allowSaves: true);
    final saved = await library.save(result);
    expect(store.itemBySource('giphy', 'abc'), same(saved));
    expect(store.itemBySourcePage(result.pageUrl!), same(saved));
    await store.deleteItem(saved);
    expect(store.itemBySource('giphy', 'abc'), isNull);
  });
}
