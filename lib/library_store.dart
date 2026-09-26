import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class LibraryFolder {
  LibraryFolder({required this.id, required this.name, this.parentId});
  final String id;
  String name;
  String? parentId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };
  factory LibraryFolder.fromJson(Map<String, dynamic> data) => LibraryFolder(
    id: data['id'] as String,
    name: data['name'] as String,
    parentId: data['parentId'] as String?,
  );
}

class LibraryItem {
  LibraryItem({
    required this.id,
    required this.name,
    required this.filename,
    required this.kind,
    this.folderId,
    this.favorite = false,
    this.useCount = 0,
    this.sourceType = 'upload',
    String? sourceId,
    this.sourcePage,
    this.licenseLabel,
  }) : sourceId = sourceId ?? id;
  final String id;
  String name;
  final String filename;
  final String kind;
  String? folderId;
  bool favorite;
  int useCount;
  final String sourceType;
  final String sourceId;
  final String? sourcePage;
  final String? licenseLabel;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filename': filename,
    'kind': kind,
    'folderId': folderId,
    'favorite': favorite,
    'useCount': useCount,
    'sourceType': sourceType,
    'sourceId': sourceId,
    'sourcePage': sourcePage,
    'licenseLabel': licenseLabel,
  };
  factory LibraryItem.fromJson(Map<String, dynamic> data) => LibraryItem(
    id: data['id'] as String,
    name: data['name'] as String,
    filename: data['filename'] as String,
    kind: data['kind'] as String,
    folderId: data['folderId'] as String?,
    favorite: data['favorite'] as bool? ?? false,
    useCount: data['useCount'] as int? ?? 0,
    sourceType:
        data['sourceType'] as String? ??
        _legacySourceType(data['sourcePage'] as String?),
    sourceId:
        data['sourceId'] as String? ??
        _legacySourceId(data['id'] as String, data['sourcePage'] as String?),
    sourcePage: data['sourcePage'] as String?,
    licenseLabel: data['licenseLabel'] as String?,
  );

  static String _legacySourceType(String? page) =>
      page?.startsWith('https://giphy.com/gifs/') == true ? 'giphy' : 'upload';

  static String _legacySourceId(String id, String? page) {
    if (_legacySourceType(page) == 'giphy') {
      return Uri.tryParse(page ?? '')?.pathSegments.lastOrNull
              ?.split('-')
              .last ??
          id;
    }
    return id;
  }
}

class LibraryStore extends ChangeNotifier {
  LibraryStore({this.supportDirectory});

  final Directory? supportDirectory;
  final folders = <LibraryFolder>[];
  final items = <LibraryItem>[];
  final folderVersions = <String, String>{};
  final itemVersions = <String, String>{};
  final dirtyFolders = <String>{};
  final dirtyItems = <String>{};
  final deletedFolders = <String>{};
  final deletedItems = <String>{};
  String? accountId;
  late Directory root;
  late Directory media;

  Future<void> load() => openAccount(null);

  Future<void> openAccount(String? userId) async {
    if (userId != null && !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(userId)) {
      throw ArgumentError.value(userId, 'userId');
    }
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    accountId = userId;
    root = Directory(
      userId == null
          ? '${support.path}${Platform.pathSeparator}library'
          : '${support.path}${Platform.pathSeparator}accounts${Platform.pathSeparator}$userId${Platform.pathSeparator}library',
    );
    media = Directory('${root.path}${Platform.pathSeparator}media');
    await media.create(recursive: true);
    folders.clear();
    items.clear();
    folderVersions.clear();
    itemVersions.clear();
    dirtyFolders.clear();
    dirtyItems.clear();
    deletedFolders.clear();
    deletedItems.clear();
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    final backup = File('${index.path}.bak');
    if (!await index.exists() && await backup.exists()) {
      await backup.rename(index.path);
    }
    if (!await index.exists()) {
      notifyListeners();
      return;
    }
    final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
    folders.addAll(
      (data['folders'] as List<dynamic>? ?? []).map(
        (e) => LibraryFolder.fromJson(e as Map<String, dynamic>),
      ),
    );
    items.addAll(
      (data['items'] as List<dynamic>? ?? []).map(
        (e) => LibraryItem.fromJson(e as Map<String, dynamic>),
      ),
    );
    folderVersions.addAll(
      (data['folderVersions'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    );
    itemVersions.addAll(
      (data['itemVersions'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, value as String),
      ),
    );
    dirtyFolders.addAll(
      (data['dirtyFolders'] as List<dynamic>? ?? []).cast<String>(),
    );
    dirtyItems.addAll(
      (data['dirtyItems'] as List<dynamic>? ?? []).cast<String>(),
    );
    deletedFolders.addAll(
      (data['deletedFolders'] as List<dynamic>? ?? []).cast<String>(),
    );
    deletedItems.addAll(
      (data['deletedItems'] as List<dynamic>? ?? []).cast<String>(),
    );
    notifyListeners();
  }

  File fileFor(LibraryItem item) =>
      File('${media.path}${Platform.pathSeparator}${item.filename}');

  LibraryItem? itemBySource(String sourceType, String sourceId) => items
      .where(
        (item) => item.sourceType == sourceType && item.sourceId == sourceId,
      )
      .firstOrNull;

  Future<void> _save() async {
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    final temp = File('${index.path}.tmp');
    final backup = File('${index.path}.bak');
    await temp.writeAsString(
      jsonEncode({
        'version': 3,
        'folders': folders.map((e) => e.toJson()).toList(),
        'items': items.map((e) => e.toJson()).toList(),
        'folderVersions': folderVersions,
        'itemVersions': itemVersions,
        'dirtyFolders': dirtyFolders.toList(),
        'dirtyItems': dirtyItems.toList(),
        'deletedFolders': deletedFolders.toList(),
        'deletedItems': deletedItems.toList(),
      }),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await index.exists()) await index.rename(backup.path);
    try {
      await temp.rename(index.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await index.exists() && await backup.exists()) {
        await backup.rename(index.path);
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> addFolder(String name, {String? parentId}) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    if (parentId != null && !folders.any((folder) => folder.id == parentId)) {
      throw ArgumentError.value(parentId, 'parentId', 'Folder does not exist');
    }
    final folder = LibraryFolder(
      id: _uuid.v4(),
      name: clean,
      parentId: parentId,
    );
    folders.add(folder);
    dirtyFolders.add(folder.id);
    await _save();
  }

  Future<void> renameFolder(LibraryFolder folder, String name) async {
    if (name.trim().isEmpty) return;
    folder.name = name.trim();
    dirtyFolders.add(folder.id);
    await _save();
  }

  bool canMoveFolder(LibraryFolder folder, String? parentId) {
    if (parentId == folder.id) return false;
    final byId = {for (final entry in folders) entry.id: entry};
    final visited = <String>{};
    var current = parentId;
    while (current != null) {
      if (!visited.add(current) || current == folder.id) return false;
      final parent = byId[current];
      if (parent == null) return false;
      current = parent.parentId;
    }
    return true;
  }

  Future<void> moveFolder(LibraryFolder folder, String? parentId) async {
    if (!folders.contains(folder) || !canMoveFolder(folder, parentId)) {
      throw ArgumentError.value(parentId, 'parentId', 'Invalid folder move');
    }
    if (folder.parentId == parentId) return;
    folder.parentId = parentId;
    dirtyFolders.add(folder.id);
    await _save();
  }

  Future<void> deleteFolder(LibraryFolder folder) async {
    for (final child in folders.where((e) => e.parentId == folder.id)) {
      child.parentId = folder.parentId;
      dirtyFolders.add(child.id);
    }
    for (final item in items.where((e) => e.folderId == folder.id)) {
      item.folderId = folder.parentId;
      dirtyItems.add(item.id);
    }
    folders.remove(folder);
    dirtyFolders.remove(folder.id);
    deletedFolders.add(folder.id);
    await _save();
  }

  Future<void> importFiles(List<String> paths, {String? folderId}) async {
    for (final path in paths) {
      final source = File(path);
      if (!await source.exists()) continue;
      final name = source.uri.pathSegments.last;
      final extension = name.split('.').last.toLowerCase();
      if (!{'png', 'gif', 'jpg', 'jpeg', 'webp'}.contains(extension)) continue;
      final id = _uuid.v4();
      final filename = '$id.$extension';
      await source.copy('${media.path}${Platform.pathSeparator}$filename');
      final item = LibraryItem(
        id: id,
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        filename: filename,
        kind: extension == 'gif' ? 'gif' : 'sticker',
        folderId: folderId,
      );
      items.add(item);
      dirtyItems.add(item.id);
    }
    await _save();
  }

  Future<void> updateItem(
    LibraryItem item, {
    String? name,
    String? folderId,
    bool move = false,
    bool? favorite,
  }) async {
    if (name != null && name.trim().isNotEmpty) item.name = name.trim();
    if (move) item.folderId = folderId;
    if (favorite != null) item.favorite = favorite;
    dirtyItems.add(item.id);
    await _save();
  }

  Future<void> markUsed(LibraryItem item) async {
    item.useCount++;
    dirtyItems.add(item.id);
    await _save();
  }

  Future<void> deleteItem(LibraryItem item) async {
    items.remove(item);
    dirtyItems.remove(item.id);
    deletedItems.add(item.id);
    final file = fileFor(item);
    if (await file.exists()) await file.delete();
    await _save();
  }

  Future<bool> hasGuestLibrary() async {
    final support = await getApplicationSupportDirectory();
    final index = File(
      '${support.path}${Platform.pathSeparator}library${Platform.pathSeparator}index.json',
    );
    if (!await index.exists()) return false;
    final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
    return (data['folders'] as List<dynamic>? ?? []).isNotEmpty ||
        (data['items'] as List<dynamic>? ?? []).isNotEmpty;
  }

  Future<int> importGuestLibrary() async {
    if (accountId == null) {
      throw StateError('Sign in before importing the local library');
    }
    final support = await getApplicationSupportDirectory();
    final guestRoot = Directory(
      '${support.path}${Platform.pathSeparator}library',
    );
    final index = File('${guestRoot.path}${Platform.pathSeparator}index.json');
    if (!await index.exists()) return 0;
    final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
    final guestItems = (data['items'] as List<dynamic>? ?? [])
        .map((raw) => LibraryItem.fromJson(raw as Map<String, dynamic>))
        .where((item) => itemBySource(item.sourceType, item.sourceId) == null)
        .toList();
    if (guestItems.isEmpty) return 0;
    final guestFolders = (data['folders'] as List<dynamic>? ?? [])
        .map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>))
        .toList();
    final folderIds = {
      for (final folder in guestFolders) folder.id: _uuid.v4(),
    };
    for (final folder in guestFolders) {
      final copy = LibraryFolder(
        id: folderIds[folder.id]!,
        name: folder.name,
        parentId: folder.parentId == null ? null : folderIds[folder.parentId],
      );
      folders.add(copy);
      dirtyFolders.add(copy.id);
    }
    var copied = 0;
    for (final item in guestItems) {
      final source = File(
        '${guestRoot.path}${Platform.pathSeparator}media${Platform.pathSeparator}${item.filename}',
      );
      if (!await source.exists()) continue;
      final extension = item.filename.split('.').last.toLowerCase();
      final id = _uuid.v4();
      final filename = '$id.$extension';
      await source.copy('${media.path}${Platform.pathSeparator}$filename');
      final copy = LibraryItem(
        id: id,
        name: item.name,
        filename: filename,
        kind: item.kind,
        folderId: item.folderId == null ? null : folderIds[item.folderId],
        favorite: item.favorite,
        useCount: item.useCount,
        sourceType: item.sourceType,
        sourceId: item.sourceId,
        sourcePage: item.sourcePage,
        licenseLabel: item.licenseLabel,
      );
      items.add(copy);
      dirtyItems.add(copy.id);
      copied++;
    }
    await _save();
    return copied;
  }

  Future<void> acknowledgeFolder(
    String id,
    String? version, {
    Map<String, dynamic>? expected,
  }) async {
    if (version == null) {
      if (folders.any((folder) => folder.id == id)) return;
      deletedFolders.remove(id);
      folderVersions.remove(id);
    } else {
      folderVersions[id] = version;
      final current = folders.where((folder) => folder.id == id).firstOrNull;
      if (current != null &&
          expected != null &&
          jsonEncode(current.toJson()) == jsonEncode(expected)) {
        dirtyFolders.remove(id);
      }
    }
    await _save();
  }

  Future<void> acknowledgeItem(
    String id,
    String? version, {
    Map<String, dynamic>? expected,
  }) async {
    if (version == null) {
      if (items.any((item) => item.id == id)) return;
      deletedItems.remove(id);
      itemVersions.remove(id);
    } else {
      itemVersions[id] = version;
      final current = items.where((item) => item.id == id).firstOrNull;
      if (current != null &&
          expected != null &&
          jsonEncode(current.toJson()) == jsonEncode(expected)) {
        dirtyItems.remove(id);
      }
    }
    await _save();
  }

  Future<LibraryItem> importBytes(
    Uint8List bytes, {
    required String name,
    required String extension,
    String? folderId,
    String? sourceType,
    String? sourceId,
    String? sourcePage,
    String? licenseLabel,
    bool favorite = false,
  }) async {
    if (!{'png', 'gif', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
      throw ArgumentError.value(extension, 'extension');
    }
    if ((sourceType == null) != (sourceId == null)) {
      throw ArgumentError('sourceType and sourceId must be provided together');
    }
    if (sourceType != null &&
        (sourceType.trim().isEmpty || sourceId!.trim().isEmpty)) {
      throw ArgumentError('Source identity cannot be empty');
    }
    if (sourceType != null) {
      final existing = itemBySource(sourceType, sourceId!);
      if (existing != null) return existing;
    }
    final id = _uuid.v4();
    final filename = '$id.$extension';
    final file = File('${media.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes, flush: true);
    final item = LibraryItem(
      id: id,
      name: name.trim().isEmpty ? 'Untitled' : name.trim(),
      filename: filename,
      kind: extension == 'gif' ? 'gif' : 'sticker',
      folderId: folderId,
      favorite: favorite,
      sourceType: sourceType ?? 'upload',
      sourceId: sourceId,
      sourcePage: sourcePage,
      licenseLabel: licenseLabel,
    );
    items.add(item);
    dirtyItems.add(id);
    await _save();
    return item;
  }

  Future<void> resolveConflict(
    String entity,
    String id, {
    required bool keepDevice,
    String? remoteVersion,
  }) async {
    final versions = entity == 'folder' ? folderVersions : itemVersions;
    final dirty = entity == 'folder' ? dirtyFolders : dirtyItems;
    final deleted = entity == 'folder' ? deletedFolders : deletedItems;
    if (keepDevice) {
      if (remoteVersion == null) {
        versions.remove(id);
      } else {
        versions[id] = remoteVersion;
      }
      if (remoteVersion == null && deleted.contains(id)) deleted.remove(id);
    } else {
      dirty.remove(id);
      deleted.remove(id);
      versions.remove(id);
    }
    await _save();
  }

  Future<void> mergeRemote({
    required Map<String, LibraryFolder> remoteFolders,
    required Map<String, LibraryItem> remoteItems,
    required Map<String, String> remoteFolderVersions,
    required Map<String, String> remoteItemVersions,
  }) async {
    final removedFolderIds = folders
        .where(
          (folder) =>
              !dirtyFolders.contains(folder.id) &&
              !deletedFolders.contains(folder.id) &&
              !remoteFolders.containsKey(folder.id),
        )
        .map((folder) => folder.id)
        .toList();
    folders.removeWhere((folder) => removedFolderIds.contains(folder.id));
    for (final id in removedFolderIds) {
      folderVersions.remove(id);
    }
    for (final entry in remoteFolders.entries) {
      if (dirtyFolders.contains(entry.key) ||
          deletedFolders.contains(entry.key)) {
        continue;
      }
      folders.removeWhere((folder) => folder.id == entry.key);
      folders.add(entry.value);
      folderVersions[entry.key] = remoteFolderVersions[entry.key]!;
    }
    final removed = items
        .where(
          (item) =>
              !dirtyItems.contains(item.id) &&
              !deletedItems.contains(item.id) &&
              !remoteItems.containsKey(item.id),
        )
        .toList();
    items.removeWhere((item) => removed.contains(item));
    for (final item in removed) {
      final file = fileFor(item);
      if (await file.exists()) await file.delete();
      itemVersions.remove(item.id);
    }
    for (final entry in remoteItems.entries) {
      if (dirtyItems.contains(entry.key) || deletedItems.contains(entry.key)) {
        continue;
      }
      final old = items.where((item) => item.id == entry.key).firstOrNull;
      if (old != null && old.filename != entry.value.filename) {
        final oldFile = fileFor(old);
        if (await oldFile.exists()) await oldFile.delete();
      }
      items.removeWhere((item) => item.id == entry.key);
      items.add(entry.value);
      itemVersions[entry.key] = remoteItemVersions[entry.key]!;
    }
    await _save();
  }
}
