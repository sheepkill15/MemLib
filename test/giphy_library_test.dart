import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/giphy_library.dart';
import 'package:memlib/giphy_service.dart';
import 'package:memlib/library_store.dart';

void main() {
  late Directory sandbox;
  late LibraryStore store;
  late int downloads;
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
    downloads = 0;
  });

  tearDown(() async {
    store.dispose();
    await sandbox.delete(recursive: true);
  });

  Future<Uint8List> download(GiphyResult _) async {
    downloads++;
    return Uint8List.fromList('GIF89a'.codeUnits);
  }

  test(
    'saving and starring the same GIPHY result keeps one synced item',
    () async {
      final library = GiphyLibrary(store, download, allowSaves: true);
      final saved = await library.save(result, folderId: 'reactions');
      expect(saved.folderId, 'reactions');
      expect(saved.favorite, isFalse);
      expect(saved.sourcePage, result.pageUrl);
      expect(saved.sourceType, 'giphy');
      expect(saved.sourceId, 'abc');
      expect(await store.fileFor(saved).readAsBytes(), 'GIF89a'.codeUnits);

      final starred = await library.toggleFavorite(result);
      expect(starred.id, saved.id);
      expect(starred.favorite, isTrue);
      expect(store.items, hasLength(1));
      expect(downloads, 1);
      expect(store.dirtyItems, contains(saved.id));

      await library.toggleFavorite(result);
      expect(saved.favorite, isFalse);
    },
  );

  test(
    'KLIPY GIF and sticker saves keep separate provider identities',
    () async {
      final library = GiphyLibrary(store, download, allowSaves: true);
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
      expect(store.items, hasLength(2));
      expect(await store.fileFor(savedGif).readAsBytes(), 'GIF89a'.codeUnits);
    },
  );

  test('saving is blocked until GIPHY permission flag is enabled', () async {
    final library = GiphyLibrary(store, download, allowSaves: false);
    await expectLater(library.save(result), throwsStateError);
    expect(downloads, 0);
    expect(store.items, isEmpty);
  });

  test(
    'keyboard download can be imported without fetching the GIF again',
    () async {
      final library = GiphyLibrary(store, download, allowSaves: true);
      final saved = await library.toggleFavorite(
        result,
        downloadedBytes: Uint8List.fromList('GIF89a'.codeUnits),
      );
      expect(saved.favorite, isTrue);
      expect(saved.sourcePage, result.pageUrl);
      expect(downloads, 0);
    },
  );

  test('replaying a queued favourite request is idempotent', () async {
    final library = GiphyLibrary(store, download, allowSaves: true);
    final first = await library.setFavorite(result, true);
    final replayed = await library.setFavorite(result, true);
    expect(replayed.id, first.id);
    expect(replayed.favorite, isTrue);
    expect(store.items, hasLength(1));
    expect(downloads, 1);

    await library.setFavorite(result, false);
    await library.setFavorite(result, false);
    expect(replayed.favorite, isFalse);
  });

  test(
    'the provider ID deduplicates even when the GIPHY page changes',
    () async {
      final library = GiphyLibrary(store, download, allowSaves: true);
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
      expect(downloads, 1);
    },
  );
}
