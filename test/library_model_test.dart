import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';

void main() {
  test('library item metadata survives serialization', () {
    final item = LibraryItem(
      id: 'item-1',
      name: 'Wave',
      filename: 'item-1.gif',
      kind: 'gif',
      folderId: 'folder-1',
      favorite: true,
      useCount: 7,
      sourceType: 'giphy',
      sourceId: 'abc',
    );
    final restored = LibraryItem.fromJson(item.toJson());
    expect(restored.name, 'Wave');
    expect(restored.folderId, 'folder-1');
    expect(restored.favorite, true);
    expect(restored.useCount, 7);
    expect(restored.sourceType, 'giphy');
    expect(restored.sourceId, 'abc');
  });

  test('older saved GIPHY entries recover provider identity from the page', () {
    final restored = LibraryItem.fromJson({
      'id': 'old-item',
      'name': 'Wave',
      'filename': 'old-item.gif',
      'kind': 'gif',
      'sourcePage': 'https://giphy.com/gifs/wave-abc',
    });
    expect(restored.sourceType, 'giphy');
    expect(restored.sourceId, 'abc');
  });
}
