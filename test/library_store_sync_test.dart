import 'dart:convert';
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

  test('switching accounts restores each separate local library', () async {
    store.dispose();
    store = LibraryStore(supportDirectory: sandbox);

    await store.load();
    await store.addFolder('Guest folder');

    const accountId = 'f27ad7e8-2765-4f69-944d-884872179978';
    await store.openAccount(accountId);
    expect(store.folders, isEmpty);
    await store.addFolder('Account folder');

    await store.openAccount(null);
    expect(store.folders.single.name, 'Guest folder');

    await store.openAccount(accountId);
    expect(store.folders.single.name, 'Account folder');
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

  test('nested folder moves persist and reject cycles', () async {
    await store.addFolder('Parent');
    final parent = store.folders.single;
    await store.addFolder('Child', parentId: parent.id);
    final child = store.folders.last;
    await store.addFolder('Destination');
    final destination = store.folders.last;

    expect(store.canMoveFolder(parent, child.id), isFalse);
    await expectLater(store.moveFolder(parent, child.id), throwsArgumentError);
    await store.moveFolder(child, destination.id);
    expect(child.parentId, destination.id);
    expect(store.dirtyFolders, contains(child.id));

    final index = jsonDecode(
      await File('${sandbox.path}${Platform.pathSeparator}index.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    final saved = (index['folders'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(
      saved.where((f) => f['id'] == child.id).single['parentId'],
      destination.id,
    );
  });

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
