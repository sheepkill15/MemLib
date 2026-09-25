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

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parentId': parentId};
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
  });
  final String id;
  String name;
  final String filename;
  final String kind;
  String? folderId;
  bool favorite;
  int useCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filename': filename,
    'kind': kind,
    'folderId': folderId,
    'favorite': favorite,
    'useCount': useCount,
  };
  factory LibraryItem.fromJson(Map<String, dynamic> data) => LibraryItem(
    id: data['id'] as String,
    name: data['name'] as String,
    filename: data['filename'] as String,
    kind: data['kind'] as String,
    folderId: data['folderId'] as String?,
    favorite: data['favorite'] as bool? ?? false,
    useCount: data['useCount'] as int? ?? 0,
  );
}

class LibraryStore extends ChangeNotifier {
  final folders = <LibraryFolder>[];
  final items = <LibraryItem>[];
  late final Directory root;
  late final Directory media;

  Future<void> load() async {
    root = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}library');
    media = Directory('${root.path}${Platform.pathSeparator}media');
    await media.create(recursive: true);
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    final backup = File('${index.path}.bak');
    if (!await index.exists() && await backup.exists()) await backup.rename(index.path);
    if (!await index.exists()) return;
    final data = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
    folders.addAll((data['folders'] as List<dynamic>? ?? []).map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>)));
    items.addAll((data['items'] as List<dynamic>? ?? []).map((e) => LibraryItem.fromJson(e as Map<String, dynamic>)));
    notifyListeners();
  }

  File fileFor(LibraryItem item) => File('${media.path}${Platform.pathSeparator}${item.filename}');

  Future<void> _save() async {
    final index = File('${root.path}${Platform.pathSeparator}index.json');
    final temp = File('${index.path}.tmp');
    final backup = File('${index.path}.bak');
    await temp.writeAsString(jsonEncode({
      'version': 1,
      'folders': folders.map((e) => e.toJson()).toList(),
      'items': items.map((e) => e.toJson()).toList(),
    }), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await index.exists()) await index.rename(backup.path);
    try {
      await temp.rename(index.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await index.exists() && await backup.exists()) await backup.rename(index.path);
      rethrow;
    }
    notifyListeners();
  }

  Future<void> addFolder(String name, {String? parentId}) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    folders.add(LibraryFolder(id: _uuid.v4(), name: clean, parentId: parentId));
    await _save();
  }

  Future<void> renameFolder(LibraryFolder folder, String name) async {
    if (name.trim().isEmpty) return;
    folder.name = name.trim();
    await _save();
  }

  Future<void> deleteFolder(LibraryFolder folder) async {
    for (final child in folders.where((e) => e.parentId == folder.id)) {
      child.parentId = folder.parentId;
    }
    for (final item in items.where((e) => e.folderId == folder.id)) {
      item.folderId = folder.parentId;
    }
    folders.remove(folder);
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
      items.add(LibraryItem(
        id: id,
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        filename: filename,
        kind: extension == 'gif' ? 'gif' : 'sticker',
        folderId: folderId,
      ));
    }
    await _save();
  }

  Future<void> updateItem(LibraryItem item, {String? name, String? folderId, bool move = false, bool? favorite}) async {
    if (name != null && name.trim().isNotEmpty) item.name = name.trim();
    if (move) item.folderId = folderId;
    if (favorite != null) item.favorite = favorite;
    await _save();
  }

  Future<void> markUsed(LibraryItem item) async {
    item.useCount++;
    await _save();
  }

  Future<void> deleteItem(LibraryItem item) async {
    items.remove(item);
    final file = fileFor(item);
    if (await file.exists()) await file.delete();
    await _save();
  }
}
