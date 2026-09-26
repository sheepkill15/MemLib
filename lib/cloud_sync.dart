import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'library_store.dart';

class SyncConflict implements Exception {
  const SyncConflict(this.entity, this.id);
  final String entity;
  final String id;

  @override
  String toString() =>
      'A $entity changed on another device while this device was offline. Resolve the conflict before syncing again.';
}

class RemoteFolder {
  const RemoteFolder(this.folder, this.version);
  final LibraryFolder folder;
  final String version;
}

class RemoteItem {
  const RemoteItem(this.item, this.version, this.storagePath);
  final LibraryItem item;
  final String version;
  final String storagePath;
}

abstract class RemoteLibrary {
  Future<List<RemoteFolder>> fetchFolders(String ownerId);
  Future<List<RemoteItem>> fetchItems(String ownerId);
  Future<String> createFolder(String ownerId, LibraryFolder folder);
  Future<String?> updateFolder(
    String ownerId,
    LibraryFolder folder,
    String version,
  );
  Future<bool> deleteFolder(String ownerId, String id, String version);
  Future<String> createItem(
    String ownerId,
    LibraryItem item,
    String storagePath,
  );
  Future<String?> updateItem(String ownerId, LibraryItem item, String version);
  Future<bool> deleteItem(String ownerId, String id, String version);
  Future<void> uploadMedia(String path, File file);
  Future<List<int>> downloadMedia(String path);
  Future<void> deleteMedia(String path);
}

class SupabaseRemoteLibrary implements RemoteLibrary {
  SupabaseRemoteLibrary(this.client);
  final SupabaseClient client;

  Future<List<Map<String, dynamic>>> _fetchAll(
    String table,
    String ownerId,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var start = 0; ; start += 1000) {
      final page = await client
          .from(table)
          .select()
          .eq('owner_id', ownerId)
          .order('id')
          .range(start, start + 999);
      rows.addAll((page as List<dynamic>).cast<Map<String, dynamic>>());
      if (page.length < 1000) return rows;
    }
  }

  @override
  Future<List<RemoteFolder>> fetchFolders(String ownerId) async =>
      (await _fetchAll('folders', ownerId))
          .map(
            (row) => RemoteFolder(
              LibraryFolder(
                id: row['id'] as String,
                name: row['name'] as String,
                parentId: row['parent_id'] as String?,
              ),
              row['updated_at'] as String,
            ),
          )
          .toList();

  @override
  Future<List<RemoteItem>> fetchItems(String ownerId) async =>
      (await _fetchAll(
        'library_items',
        ownerId,
      )).where((row) => row['source'] == 'upload').map((row) {
        final path = row['storage_path'] as String;
        final id = row['id'] as String;
        if (!path.startsWith('$ownerId/') ||
            !RegExp(
              '^$id\\.(png|gif|jpe?g|webp)\$',
              caseSensitive: false,
            ).hasMatch(path.split('/').last)) {
          throw FormatException('Invalid media path for item $id');
        }
        return RemoteItem(
          LibraryItem(
            id: id,
            name: row['title'] as String,
            filename: path.split('/').last,
            kind: row['kind'] as String,
            folderId: row['folder_id'] as String?,
            favorite: row['favorite'] as bool? ?? false,
            useCount: row['use_count'] as int? ?? 0,
            sourceType: row['source_type'] as String? ?? 'upload',
            sourceId: row['source_id'] as String?,
            sourcePage: row['source_page'] as String?,
            licenseLabel: row['license_label'] as String?,
          ),
          row['updated_at'] as String,
          path,
        );
      }).toList();

  @override
  Future<String> createFolder(String ownerId, LibraryFolder folder) async {
    final row = await client
        .from('folders')
        .insert({
          'id': folder.id,
          'owner_id': ownerId,
          'name': folder.name,
          'parent_id': folder.parentId,
        })
        .select('updated_at')
        .single();
    return row['updated_at'] as String;
  }

  @override
  Future<String?> updateFolder(
    String ownerId,
    LibraryFolder folder,
    String version,
  ) async {
    final row = await client
        .from('folders')
        .update({'name': folder.name, 'parent_id': folder.parentId})
        .eq('owner_id', ownerId)
        .eq('id', folder.id)
        .eq('updated_at', version)
        .select('updated_at')
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<bool> deleteFolder(String ownerId, String id, String version) async {
    final row = await client
        .from('folders')
        .delete()
        .eq('owner_id', ownerId)
        .eq('id', id)
        .eq('updated_at', version)
        .select('id')
        .maybeSingle();
    return row != null;
  }

  @override
  Future<String> createItem(
    String ownerId,
    LibraryItem item,
    String storagePath,
  ) async {
    final row = await client
        .from('library_items')
        .insert({
          'id': item.id,
          'owner_id': ownerId,
          'folder_id': item.folderId,
          'title': item.name,
          'kind': item.kind,
          'source': 'upload',
          'storage_path': storagePath,
          'favorite': item.favorite,
          'use_count': item.useCount,
          'source_type': item.sourceType,
          'source_id': item.sourceId,
          if (item.sourcePage != null) 'source_page': item.sourcePage,
          if (item.licenseLabel != null) 'license_label': item.licenseLabel,
        })
        .select('updated_at')
        .single();
    return row['updated_at'] as String;
  }

  @override
  Future<String?> updateItem(
    String ownerId,
    LibraryItem item,
    String version,
  ) async {
    final row = await client
        .from('library_items')
        .update({
          'folder_id': item.folderId,
          'title': item.name,
          'favorite': item.favorite,
          'use_count': item.useCount,
        })
        .eq('owner_id', ownerId)
        .eq('id', item.id)
        .eq('updated_at', version)
        .select('updated_at')
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<bool> deleteItem(String ownerId, String id, String version) async {
    final row = await client
        .from('library_items')
        .delete()
        .eq('owner_id', ownerId)
        .eq('id', id)
        .eq('updated_at', version)
        .select('id')
        .maybeSingle();
    return row != null;
  }

  @override
  Future<void> uploadMedia(String path, File file) async {
    final extension = file.path.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    await client.storage
        .from('library-media')
        .uploadBinary(
          path,
          await file.readAsBytes(),
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
  }

  @override
  Future<List<int>> downloadMedia(String path) =>
      client.storage.from('library-media').download(path);

  @override
  Future<void> deleteMedia(String path) async {
    await client.storage.from('library-media').remove([path]);
  }
}

class CloudSyncEngine {
  CloudSyncEngine(this.store, this.remote, this.ownerId);
  final LibraryStore store;
  final RemoteLibrary remote;
  final String ownerId;

  Future<void> sync() async {
    if (store.accountId != ownerId) {
      throw StateError('Account changed during sync');
    }
    var remoteFolders = {
      for (final row in await remote.fetchFolders(ownerId)) row.folder.id: row,
    };
    var remoteItems = {
      for (final row in await remote.fetchItems(ownerId)) row.item.id: row,
    };
    _checkConflicts(remoteFolders, remoteItems);

    final pendingFolders = store.folders
        .where((folder) => store.dirtyFolders.contains(folder.id))
        .toList();
    pendingFolders.sort(
      (a, b) => _folderDepth(
        a,
        pendingFolders,
      ).compareTo(_folderDepth(b, pendingFolders)),
    );
    for (final folder in pendingFolders) {
      final expected = folder.toJson();
      final version = store.folderVersions[folder.id];
      final updated = version == null
          ? await remote.createFolder(ownerId, folder)
          : await remote.updateFolder(ownerId, folder, version);
      if (updated == null) throw SyncConflict('folder', folder.id);
      await store.acknowledgeFolder(folder.id, updated, expected: expected);
    }

    for (final item
        in store.items
            .where((item) => store.dirtyItems.contains(item.id))
            .toList()) {
      final expected = item.toJson();
      final version = store.itemVersions[item.id];
      String? updated;
      if (version == null) {
        final file = store.fileFor(item);
        if (!await file.exists()) {
          throw FileSystemException('Local media is missing', file.path);
        }
        final path = '$ownerId/${item.filename}';
        await remote.uploadMedia(path, file);
        updated = await remote.createItem(ownerId, item, path);
      } else {
        updated = await remote.updateItem(ownerId, item, version);
      }
      if (updated == null) throw SyncConflict('item', item.id);
      await store.acknowledgeItem(item.id, updated, expected: expected);
    }

    for (final id in store.deletedItems.toList()) {
      final version = store.itemVersions[id];
      if (version != null && !await remote.deleteItem(ownerId, id, version)) {
        throw SyncConflict('item', id);
      }
      final path = remoteItems[id]?.storagePath;
      await store.acknowledgeItem(id, null);
      if (path != null) {
        try {
          await remote.deleteMedia(path);
        } catch (_) {
          /* Metadata is already removed; an orphan can be cleaned later. */
        }
      }
    }
    for (final id in store.deletedFolders.toList()) {
      final version = store.folderVersions[id];
      if (version != null && !await remote.deleteFolder(ownerId, id, version)) {
        throw SyncConflict('folder', id);
      }
      await store.acknowledgeFolder(id, null);
    }

    remoteFolders = {
      for (final row in await remote.fetchFolders(ownerId)) row.folder.id: row,
    };
    remoteItems = {
      for (final row in await remote.fetchItems(ownerId)) row.item.id: row,
    };
    for (final row in remoteItems.values) {
      if (store.dirtyItems.contains(row.item.id) ||
          store.deletedItems.contains(row.item.id)) {
        continue;
      }
      final file = store.fileFor(row.item);
      if (await file.exists()) continue;
      final bytes = await remote.downloadMedia(row.storagePath);
      final temp = File('${file.path}.download');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    }
    await store.mergeRemote(
      remoteFolders: {
        for (final entry in remoteFolders.entries)
          entry.key: entry.value.folder,
      },
      remoteItems: {
        for (final entry in remoteItems.entries) entry.key: entry.value.item,
      },
      remoteFolderVersions: {
        for (final entry in remoteFolders.entries)
          entry.key: entry.value.version,
      },
      remoteItemVersions: {
        for (final entry in remoteItems.entries) entry.key: entry.value.version,
      },
    );
  }

  void _checkConflicts(
    Map<String, RemoteFolder> folders,
    Map<String, RemoteItem> items,
  ) {
    for (final id in {...store.dirtyFolders, ...store.deletedFolders}) {
      final expected = store.folderVersions[id];
      final current = folders[id]?.version;
      if (expected != current && (expected != null || current != null)) {
        throw SyncConflict('folder', id);
      }
    }
    for (final id in {...store.dirtyItems, ...store.deletedItems}) {
      final expected = store.itemVersions[id];
      final current = items[id]?.version;
      if (expected != current && (expected != null || current != null)) {
        throw SyncConflict('item', id);
      }
    }
  }

  int _folderDepth(LibraryFolder folder, List<LibraryFolder> pending) {
    var depth = 0;
    var parent = folder.parentId;
    while (parent != null && depth < pending.length) {
      depth++;
      parent = pending
          .where((candidate) => candidate.id == parent)
          .firstOrNull
          ?.parentId;
    }
    return depth;
  }
}
