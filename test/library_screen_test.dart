import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';
import 'package:memlib/main.dart';

void main() {
  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  final display = {
    'id': 'test-screen',
    'size': {'width': 1920.0, 'height': 1080.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1920.0, 'height': 1040.0},
  };

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => switch (call.method) {
        'getId' => 1,
        'getBounds' => {'x': 0.0, 'y': 0.0, 'width': 620.0, 'height': 540.0},
        'isMinimized' => false,
        _ => null,
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      screenChannel,
      (call) async => switch (call.method) {
        'getPrimaryDisplay' => display,
        'getAllDisplays' => {'displays': [display]},
        'getCursorScreenPoint' => {'dx': 300.0, 'dy': 300.0},
        _ => null,
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(screenChannel, null);
  });

  testWidgets('folder sidebar and name dialog dispose cleanly', (tester) async {
    final store = LibraryStore();
    store.folders.add(LibraryFolder(id: 'folder-1', name: 'Reactions'));
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
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

  testWidgets('Windows quick picker opens without chrome and closes with Escape', (tester) async {
    final store = LibraryStore();
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.text('Find a sticker or GIF'), findsOneWidget);
    expect(find.text('Type to search   ·   Arrow keys to move   ·   Enter to paste   ·   Esc to close'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.text('GIPHY'));
    await tester.pumpAndSettle();
    expect(find.text('Search GIPHY'), findsOneWidget);
    expect(find.text('Add a GIPHY API key to search'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
