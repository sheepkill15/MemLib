import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
    this.filename,
    required this.kind,
    this.folderId,
    this.favorite = false,
    List<String> tags = const [],
    this.useCount = 0,
    this.sourceType = 'upload',
    String? sourceId,
    this.sourcePage,
    this.licenseLabel,
    this.mediaUrl,
    this.previewUrl,
  }) : assert((filename == null) != (mediaUrl == null)),
       tags = List<String>.of(tags),
       sourceId = sourceId ?? id;
  final String id;
  String name;

  /// The local media file, for uploaded items. Null for linked items.
  final String? filename;
  final String kind;
  String? folderId;
  bool favorite;
  List<String> tags;
  int useCount;
  final String sourceType;
  final String sourceId;
  final String? sourcePage;
  final String? licenseLabel;

  /// The provider's media URL, for items saved as links (KLIPY, Pinterest).
  /// These keep only metadata; the image is loaded from the provider.
  final String? mediaUrl;
  final String? previewUrl;

  bool get isLinked => mediaUrl != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filename': filename,
    'kind': kind,
    'folderId': folderId,
    'favorite': favorite,
    'tags': tags,
    'useCount': useCount,
    'sourceType': sourceType,
    'sourceId': sourceId,
    'sourcePage': sourcePage,
    'licenseLabel': licenseLabel,
    'mediaUrl': mediaUrl,
    'previewUrl': previewUrl,
  };
  factory LibraryItem.fromJson(Map<String, dynamic> data) => LibraryItem(
    id: data['id'] as String,
    name: data['name'] as String,
    filename: data['filename'] as String?,
    kind: data['kind'] as String,
    folderId: data['folderId'] as String?,
    favorite: data['favorite'] as bool? ?? false,
    tags: (data['tags'] as List<dynamic>? ?? []).cast<String>(),
    useCount: data['useCount'] as int? ?? 0,
    sourceType:
        data['sourceType'] as String? ??
        _legacySourceType(data['sourcePage'] as String?),
    sourceId:
        data['sourceId'] as String? ??
        _legacySourceId(data['id'] as String, data['sourcePage'] as String?),
    sourcePage: data['sourcePage'] as String?,
    licenseLabel: data['licenseLabel'] as String?,
    mediaUrl: data['mediaUrl'] as String?,
    previewUrl: data['previewUrl'] as String?,
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

  /// The local media file of an uploaded item. Linked items have none.
  File fileFor(LibraryItem item) {
    final filename = item.filename;
    if (filename == null) {
      throw StateError('${item.name} is a linked item without a local file');
    }
    return File('${media.path}${Platform.pathSeparator}$filename');
  }

  Future<void> _deleteMediaOf(LibraryItem item) async {
    if (item.filename == null) return;
    final file = fileFor(item);
    if (await file.exists()) await file.delete();
  }

  Map<String, LibraryItem>? _bySource;
  Map<String, LibraryItem>? _byPage;
  int _indexedCount = -1;

  /// Lookups by provider identity run for every KLIPY and Pinterest tile, so
  /// they use an index. Identity fields are final; the index is rebuilt when
  /// the item list changes length or the store notifies.
  void _ensureIndex() {
    if (_bySource != null && _indexedCount == items.length) return;
    final bySource = <String, LibraryItem>{};
    final byPage = <String, LibraryItem>{};
    for (final item in items) {
      bySource.putIfAbsent(
        '${item.sourceType}\u0000${item.sourceId}',
        () => item,
      );
      final page = item.sourcePage;
      if (page != null) byPage.putIfAbsent(page, () => item);
    }
    _bySource = bySource;
    _byPage = byPage;
    _indexedCount = items.length;
  }

  void _invalidateIndex() => _bySource = _byPage = null;

  @override
  void notifyListeners() {
    _invalidateIndex();
    super.notifyListeners();
  }

  LibraryItem? itemBySource(String sourceType, String sourceId) {
    _ensureIndex();
    return _bySource!['$sourceType\u0000$sourceId'];
  }

  LibraryItem? itemBySourcePage(String sourcePage) {
    _ensureIndex();
    return _byPage![sourcePage];
  }

  Future<void> _save({bool notify = true}) async {
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
    if (notify) notifyListeners();
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

  Future<int> importZipBytes(Uint8List bytes, {String? folderId}) async {
    if (bytes.length > 100 * 1024 * 1024) {
      throw const FormatException('ZIP files must be under 100 MB');
    }
    if (folderId != null && !folders.any((folder) => folder.id == folderId)) {
      throw ArgumentError.value(folderId, 'folderId', 'Folder does not exist');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 2000) {
      throw const FormatException('ZIP files can contain at most 2000 entries');
    }
    final entries = <(List<String>, ArchiveFile)>[];
    var totalSize = 0;
    for (final entry in archive) {
      final path = entry.name.replaceAll('\\', '/');
      if (path.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(path) ||
          path.contains('\u0000')) {
        continue;
      }
      final parts = path.split('/')..removeWhere((part) => part.isEmpty);
      if (parts.isEmpty ||
          parts.any(
            (part) => part.trim().isEmpty || part == '.' || part == '..',
          )) {
        continue;
      }
      if (entry.symbolicLink != null) continue;
      if (entry.isFile) {
        final extension = parts.last.split('.').last.toLowerCase();
        if (!{'png', 'gif', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
          continue;
        }
        if (entry.size > 30 * 1024 * 1024 || entry.size < 0) {
          throw FormatException('${entry.name} exceeds the 30 MB image limit');
        }
        totalSize += entry.size;
        if (totalSize > 250 * 1024 * 1024) {
          throw const FormatException('ZIP images exceed 250 MB in total');
        }
      }
      entries.add((parts, entry));
    }

    Future<String?> ensureFolder(List<String> path) async {
      var parent = folderId;
      for (final name in path) {
        var folder = folders
            .where(
              (folder) =>
                  folder.parentId == parent &&
                  folder.name.toLowerCase() == name.toLowerCase(),
            )
            .firstOrNull;
        if (folder == null) {
          await addFolder(name, parentId: parent);
          folder = folders.last;
        }
        parent = folder.id;
      }
      return parent;
    }

    var imported = 0;
    for (final (parts, entry) in entries) {
      if (entry.isDirectory) {
        await ensureFolder(parts);
        continue;
      }
      final name = parts.last;
      final data = entry.readBytes();
      if (data == null || data.length > 30 * 1024 * 1024) {
        throw FormatException('Could not read ZIP image ${entry.name}');
      }
      final parent = await ensureFolder(parts.sublist(0, parts.length - 1));
      await importBytes(
        data,
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        extension: name.split('.').last.toLowerCase(),
        folderId: parent,
      );
      imported++;
    }
    return imported;
  }

  Future<void> updateItem(
    LibraryItem item, {
    String? name,
    String? folderId,
    bool move = false,
    bool? favorite,
    List<String>? tags,
  }) async {
    if (name != null && name.trim().isNotEmpty) item.name = name.trim();
    if (move) item.folderId = folderId;
    if (favorite != null) item.favorite = favorite;
    if (tags != null) item.tags = _cleanTags(tags);
    dirtyItems.add(item.id);
    await _save();
  }

  List<String> _cleanTags(Iterable<String> tags) {
    final seen = <String>{};
    return tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty && seen.add(tag.toLowerCase()))
        .toList();
  }

  Future<void> addTagToItems(Iterable<LibraryItem> selected, String tag) async {
    final clean = tag.trim();
    if (clean.isEmpty) return;
    for (final item in selected) {
      if (!items.contains(item)) continue;
      final updated = _cleanTags([...item.tags, clean]);
      if (updated.length == item.tags.length) continue;
      item.tags = updated;
      dirtyItems.add(item.id);
    }
    await _save();
  }

  Future<void> removeTagFromItems(
    Iterable<LibraryItem> selected,
    String tag,
  ) async {
    for (final item in selected) {
      if (!items.contains(item)) continue;
      final updated = item.tags
          .where((entry) => entry.toLowerCase() != tag.toLowerCase())
          .toList();
      if (updated.length == item.tags.length) continue;
      item.tags = updated;
      dirtyItems.add(item.id);
    }
    await _save();
  }

  Future<void> moveItems(
    Iterable<LibraryItem> selected,
    String? folderId,
  ) async {
    if (folderId != null && !folders.any((folder) => folder.id == folderId)) {
      throw ArgumentError.value(folderId, 'folderId', 'Folder does not exist');
    }
    for (final item in selected) {
      if (!items.contains(item) || item.folderId == folderId) continue;
      item.folderId = folderId;
      dirtyItems.add(item.id);
    }
    await _save();
  }

  Future<void> deleteItems(Iterable<LibraryItem> selected) async {
    final removed = selected.where(items.contains).toList();
    for (final item in removed) {
      items.remove(item);
      dirtyItems.remove(item.id);
      deletedItems.add(item.id);
      await _deleteMediaOf(item);
    }
    if (removed.isNotEmpty) await _save();
  }

  Future<void> markUsed(LibraryItem item) async {
    item.useCount++;
    // Usage is local presentation metadata. Sending every tap through remote
    // sync replaces list entries and used to reshuffle the picker.
    await _save(notify: false);
  }

  Future<void> deleteItem(LibraryItem item) async {
    items.remove(item);
    dirtyItems.remove(item.id);
    deletedItems.add(item.id);
    await _deleteMediaOf(item);
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
      if (item.isLinked) {
        final copy = LibraryItem(
          id: _uuid.v4(),
          name: item.name,
          kind: item.kind,
          folderId: item.folderId == null ? null : folderIds[item.folderId],
          favorite: item.favorite,
          tags: item.tags,
          useCount: item.useCount,
          sourceType: item.sourceType,
          sourceId: item.sourceId,
          sourcePage: item.sourcePage,
          licenseLabel: item.licenseLabel,
          mediaUrl: item.mediaUrl,
          previewUrl: item.previewUrl,
        );
        items.add(copy);
        dirtyItems.add(copy.id);
        copied++;
        continue;
      }
      final source = File(
        '${guestRoot.path}${Platform.pathSeparator}media${Platform.pathSeparator}${item.filename}',
      );
      if (!await source.exists()) continue;
      final extension = item.filename!.split('.').last.toLowerCase();
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
    String? kind,
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
    if (kind != null && kind != 'gif' && kind != 'sticker') {
      throw ArgumentError.value(kind, 'kind');
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
      kind: kind ?? (extension == 'gif' ? 'gif' : 'sticker'),
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

  /// Saves provider media as a link: only metadata is kept, and the image is
  /// loaded from [MediaLink.mediaUrl] whenever it is shown or sent.
  Future<LibraryItem> addLinkedItem(
    MediaLink media, {
    String? folderId,
  }) async => (await addLinkedItems([media], folderId: folderId)).single;

  /// Adds several links with a single index write. Media already in the
  /// library is returned as is, after applying a requested favourite.
  Future<List<LibraryItem>> addLinkedItems(
    Iterable<MediaLink> media, {
    String? folderId,
  }) async {
    if (folderId != null && !folders.any((folder) => folder.id == folderId)) {
      throw ArgumentError.value(folderId, 'folderId', 'Folder does not exist');
    }
    final saved = <LibraryItem>[];
    var changed = false;
    for (final entry in media) {
      for (final url in [entry.mediaUrl, entry.previewUrl]) {
        if (url != null && Uri.tryParse(url)?.scheme != 'https') {
          throw ArgumentError.value(url, 'url', 'Linked media must use HTTPS');
        }
      }
      if (entry.kind != 'gif' && entry.kind != 'sticker') {
        throw ArgumentError.value(entry.kind, 'kind');
      }
      if (entry.sourceType.trim().isEmpty || entry.sourceId.trim().isEmpty) {
        throw ArgumentError('Source identity cannot be empty');
      }
      final existing = itemBySource(entry.sourceType, entry.sourceId);
      if (existing != null) {
        if (entry.favorite && !existing.favorite) {
          existing.favorite = true;
          dirtyItems.add(existing.id);
          changed = true;
        }
        saved.add(existing);
        continue;
      }
      final trimmed = entry.name.trim();
      final item = LibraryItem(
        id: _uuid.v4(),
        // Synced titles are limited to 200 characters.
        name: trimmed.isEmpty
            ? 'Untitled'
            : trimmed.length > 200
            ? trimmed.substring(0, 200).trim()
            : trimmed,
        kind: entry.kind,
        folderId: folderId,
        favorite: entry.favorite,
        sourceType: entry.sourceType,
        sourceId: entry.sourceId,
        sourcePage: entry.sourcePage,
        mediaUrl: entry.mediaUrl,
        previewUrl: entry.previewUrl,
      );
      items.add(item);
      _invalidateIndex();
      dirtyItems.add(item.id);
      saved.add(item);
      changed = true;
    }
    if (changed) await _save();
    return saved;
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
      await _deleteMediaOf(item);
      itemVersions.remove(item.id);
    }
    for (final entry in remoteItems.entries) {
      if (dirtyItems.contains(entry.key) || deletedItems.contains(entry.key)) {
        continue;
      }
      final old = items.where((item) => item.id == entry.key).firstOrNull;
      if (old != null && old.filename != entry.value.filename) {
        await _deleteMediaOf(old);
      }
      items.removeWhere((item) => item.id == entry.key);
      items.add(entry.value);
      itemVersions[entry.key] = remoteItemVersions[entry.key]!;
    }
    await _save();
  }
}

/// Provider media to keep as a link rather than a downloaded copy.
class MediaLink {
  const MediaLink({
    required this.name,
    required this.kind,
    required this.mediaUrl,
    required this.sourceType,
    required this.sourceId,
    this.previewUrl,
    this.sourcePage,
    this.favorite = false,
  });

  final String name;
  final String kind;
  final String mediaUrl;
  final String? previewUrl;
  final String sourceType;
  final String sourceId;
  final String? sourcePage;
  final bool favorite;

  MediaLink asFavorite() => MediaLink(
    name: name,
    kind: kind,
    mediaUrl: mediaUrl,
    previewUrl: previewUrl,
    sourceType: sourceType,
    sourceId: sourceId,
    sourcePage: sourcePage,
    favorite: true,
  );
}
