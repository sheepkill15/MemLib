import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/cloud_sync.dart';
import 'package:memlib/library_store.dart';

const ownerId = '11111111-1111-4111-8111-111111111111';

class MemoryRemote implements RemoteLibrary {
  final folders = <String, RemoteFolder>{};
  final items = <String, RemoteItem>{};
  final media = <String, List<int>>{};
  int revision = 0;
  String get nextVersion => 'v${++revision}';

  LibraryFolder copyFolder(LibraryFolder folder) => LibraryFolder.fromJson(folder.toJson());
  LibraryItem copyItem(LibraryItem item) => LibraryItem.fromJson(item.toJson());

  @override
  Future<List<RemoteFolder>> fetchFolders(String ownerId) async => folders.values.map((row) => RemoteFolder(copyFolder(row.folder), row.version)).toList();
  @override
  Future<List<RemoteItem>> fetchItems(String ownerId) async => items.values.map((row) => RemoteItem(copyItem(row.item), row.version, row.storagePath)).toList();
  @override
  Future<String> createFolder(String ownerId, LibraryFolder folder) async {
    final version = nextVersion;
    folders[folder.id] = RemoteFolder(copyFolder(folder), version);
    return version;
  }
  @override
  Future<String?> updateFolder(String ownerId, LibraryFolder folder, String version) async {
    if (folders[folder.id]?.version != version) return null;
    final updated = nextVersion;
    folders[folder.id] = RemoteFolder(copyFolder(folder), updated);
    return updated;
  }
  @override
  Future<bool> deleteFolder(String ownerId, String id, String version) async {
    if (folders[id]?.version != version) return false;
    folders.remove(id);
    return true;
  }
  @override
  Future<String> createItem(String ownerId, LibraryItem item, String storagePath) async {
    final version = nextVersion;
    items[item.id] = RemoteItem(copyItem(item), version, storagePath);
    return version;
  }
  @override
  Future<String?> updateItem(String ownerId, LibraryItem item, String version) async {
    final old = items[item.id];
    if (old?.version != version) return null;
    final updated = nextVersion;
    items[item.id] = RemoteItem(copyItem(item), updated, old!.storagePath);
    return updated;
  }
  @override
  Future<bool> deleteItem(String ownerId, String id, String version) async {
    if (items[id]?.version != version) return false;
    items.remove(id);
    return true;
  }
  @override
  Future<void> uploadMedia(String path, File file) async { media[path] = await file.readAsBytes(); }
  @override
  Future<List<int>> downloadMedia(String path) async => media[path]!;
  @override
  Future<void> deleteMedia(String path) async { media.remove(path); }
}

Future<LibraryStore> deviceStore(Directory sandbox, String name) async {
  final store = LibraryStore();
  store.accountId = ownerId;
  store.root = Directory('${sandbox.path}${Platform.pathSeparator}$name');
  store.media = Directory('${store.root.path}${Platform.pathSeparator}media');
  await store.media.create(recursive: true);
  return store;
}

void main() {
  late Directory sandbox;
  late LibraryStore first;
  late LibraryStore second;
  late MemoryRemote remote;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('memlib-cloud-test-');
    first = await deviceStore(sandbox, 'first');
    second = await deviceStore(sandbox, 'second');
    remote = MemoryRemote();
  });
  tearDown(() async {
    first.dispose();
    second.dispose();
    await sandbox.delete(recursive: true);
  });

  test('uploads local media and pulls it onto another device', () async {
    await first.addFolder('Reactions');
    final source = File('${sandbox.path}${Platform.pathSeparator}wave.gif');
    await source.writeAsBytes([71, 73, 70]);
    await first.importFiles([source.path], folderId: first.folders.single.id);
    await CloudSyncEngine(first, remote, ownerId).sync();
    expect(first.dirtyFolders, isEmpty);
    expect(first.dirtyItems, isEmpty);
    expect(remote.media.values.single, [71, 73, 70]);

    await CloudSyncEngine(second, remote, ownerId).sync();
    expect(second.folders.single.name, 'Reactions');
    expect(second.items.single.name, 'wave');
    expect(await second.fileFor(second.items.single).readAsBytes(), [71, 73, 70]);

    await second.updateItem(second.items.single, favorite: true);
    await CloudSyncEngine(second, remote, ownerId).sync();
    await CloudSyncEngine(first, remote, ownerId).sync();
    expect(first.items.single.favorite, isTrue);
  });

  test('propagates deletions without resurrecting old files', () async {
    final source = File('${sandbox.path}${Platform.pathSeparator}wave.gif');
    await source.writeAsBytes([71, 73, 70]);
    await first.importFiles([source.path]);
    await CloudSyncEngine(first, remote, ownerId).sync();
    await CloudSyncEngine(second, remote, ownerId).sync();
    final secondFile = second.fileFor(second.items.single);

    await first.deleteItem(first.items.single);
    await CloudSyncEngine(first, remote, ownerId).sync();
    await CloudSyncEngine(second, remote, ownerId).sync();
    expect(second.items, isEmpty);
    expect(await secondFile.exists(), isFalse);
    expect(remote.media, isEmpty);
  });

  test('reports a conflict and keeps both local and remote edits intact', () async {
    await first.addFolder('Original');
    await CloudSyncEngine(first, remote, ownerId).sync();
    await CloudSyncEngine(second, remote, ownerId).sync();
    await first.renameFolder(first.folders.single, 'On first');
    await second.renameFolder(second.folders.single, 'On second');
    await CloudSyncEngine(second, remote, ownerId).sync();

    await expectLater(CloudSyncEngine(first, remote, ownerId).sync(), throwsA(isA<SyncConflict>()));
    expect(first.folders.single.name, 'On first');
    expect(remote.folders.values.single.folder.name, 'On second');
  });
}
