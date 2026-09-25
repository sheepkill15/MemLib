import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';

void main() {
  test('library item metadata survives serialization', () {
    final item = LibraryItem(id: 'item-1', name: 'Wave', filename: 'item-1.gif', kind: 'gif', folderId: 'folder-1', favorite: true, useCount: 7);
    final restored = LibraryItem.fromJson(item.toJson());
    expect(restored.name, 'Wave');
    expect(restored.folderId, 'folder-1');
    expect(restored.favorite, true);
    expect(restored.useCount, 7);
  });
}
