import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';
import 'package:memlib/main.dart';

void main() {
  testWidgets('folder sidebar and name dialog dispose cleanly', (tester) async {
    final store = LibraryStore();
    store.folders.add(LibraryFolder(id: 'folder-1', name: 'Reactions'));
    await tester.pumpWidget(MemlibApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('Reactions'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('New folder').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Temporary');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
