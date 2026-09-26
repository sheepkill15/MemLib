import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';

void main() {
  late Directory sandbox;
  late LibraryStore store;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('memlib-store-test-');
    store = LibraryStore();
    store.root = sandbox;
    store.media = Directory('${sandbox.path}${Platform.pathSeparator}media');
    await store.media.create();
  });

  tearDown(() async {
    store.dispose();
    await sandbox.delete(recursive: true);
  });

  test(
    'local edits persist until the exact uploaded version is acknowledged',
    () async {
      await store.addFolder('Reactions');
      final folder = store.folders.single;
      final uploaded = folder.toJson();
      await store.renameFolder(folder, 'Responses');
      await store.acknowledgeFolder(folder.id, 'remote-v1', expected: uploaded);
      expect(store.dirtyFolders, contains(folder.id));
      expect(store.folderVersions[folder.id], 'remote-v1');

      await store.acknowledgeFolder(
        folder.id,
        'remote-v2',
        expected: folder.toJson(),
      );
      expect(store.dirtyFolders, isEmpty);
    },
  );

  test(
    'deleting a folder keeps its items and queues a remote delete',
    () async {
      await store.addFolder('Reactions');
      final folder = store.folders.single;
      final source = File('${sandbox.path}${Platform.pathSeparator}sample.png');
      await source.writeAsBytes([1, 2, 3]);
      await store.importFiles([source.path], folderId: folder.id);
      await store.deleteFolder(folder);

      expect(store.deletedFolders, contains(folder.id));
      expect(store.items.single.folderId, isNull);
      expect(store.dirtyItems, contains(store.items.single.id));
    },
  );

  test('remote removal deletes a clean cached media file', () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}sample.gif');
    await source.writeAsBytes([1, 2, 3]);
    await store.importFiles([source.path]);
    final item = store.items.single;
    await store.acknowledgeItem(item.id, 'remote-v1', expected: item.toJson());
    final cachedFile = store.fileFor(item);

    await store.mergeRemote(
      remoteFolders: {},
      remoteItems: {},
      remoteFolderVersions: {},
      remoteItemVersions: {},
    );
    expect(store.items, isEmpty);
    expect(await cachedFile.exists(), isFalse);
  });

  test(
    'provider identity skips a repeated import with a different path',
    () async {
      final first = await store.importBytes(
        Uint8List.fromList([1, 2, 3]),
        name: 'Pin',
        extension: 'png',
        sourceType: 'pinterest',
        sourceId: 'pin-42',
        sourcePage: 'https://www.pinterest.com/pin/42/',
      );
      final repeated = await store.importBytes(
        Uint8List.fromList([4, 5, 6]),
        name: 'Pin from another URL',
        extension: 'png',
        sourceType: 'pinterest',
        sourceId: 'pin-42',
        sourcePage: 'https://www.pinterest.com/pin/42/?ref=board',
      );
      expect(repeated.id, first.id);
      expect(store.items, hasLength(1));
      expect(await store.fileFor(first).readAsBytes(), [1, 2, 3]);
    },
  );
}
