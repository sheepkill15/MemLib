import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/library_store.dart';
import 'package:memlib/main.dart';
import 'package:memlib/giphy_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStore extends LibraryStore {
  @override
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
    final item = LibraryItem(
      id: 'saved-${sourceId ?? items.length}',
      name: name,
      filename: 'sample.$extension',
      kind: 'gif',
      folderId: folderId,
      sourceType: sourceType ?? 'upload',
      sourceId: sourceId,
      sourcePage: sourcePage,
      favorite: favorite,
    );
    items.add(item);
    notifyListeners();
    return item;
  }

  @override
  Future<void> updateItem(
    LibraryItem item, {
    String? name,
    String? folderId,
    bool move = false,
    bool? favorite,
    List<String>? tags,
  }) async {
    if (move) item.folderId = folderId;
    if (name != null) item.name = name;
    if (favorite != null) item.favorite = favorite;
    if (tags != null) item.tags = tags;
    notifyListeners();
  }

  @override
  Future<void> addTagToItems(Iterable<LibraryItem> selected, String tag) async {
    for (final item in selected) {
      if (!item.tags.contains(tag)) item.tags.add(tag);
    }
    notifyListeners();
  }

  @override
  Future<void> moveItems(
    Iterable<LibraryItem> selected,
    String? folderId,
  ) async {
    for (final item in selected) {
      item.folderId = folderId;
    }
    notifyListeners();
  }

  @override
  Future<void> deleteItems(Iterable<LibraryItem> selected) async {
    items.removeWhere(selected.toSet().contains);
    notifyListeners();
  }
}

void main() {
  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel(
    'dev.leanflutter.plugins/screen_retriever',
  );
  final display = {
    'id': 'test-screen',
    'size': {'width': 1920.0, 'height': 1080.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1920.0, 'height': 1040.0},
  };

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          windowChannel,
          (call) async => switch (call.method) {
            'getId' => 1,
            'getBounds' => {
              'x': 0.0,
              'y': 0.0,
              'width': 620.0,
              'height': 540.0,
            },
            'isMinimized' => false,
            _ => null,
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          screenChannel,
          (call) async => switch (call.method) {
            'getPrimaryDisplay' => display,
            'getAllDisplays' => {
              'displays': [display],
            },
            'getCursorScreenPoint' => {'dx': 300.0, 'dy': 300.0},
            _ => null,
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
  });

  testWidgets('folder sidebar and name dialog dispose cleanly', (tester) async {
    final store = LibraryStore();
    store.folders.add(LibraryFolder(id: 'folder-1', name: 'Reactions'));
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    expect(find.text('Reactions'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('New folder').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Temporary');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'library root shows folders before loose items and opens subfolders',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _MemoryStore();
      final media = Directory.systemTemp.createTempSync('memlib-ui-media-');
      store.media = media;
      addTearDown(() => media.deleteSync(recursive: true));
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      );
      File('${media.path}${Platform.pathSeparator}loose.png')
          .writeAsBytesSync(png);
      File('${media.path}${Platform.pathSeparator}nested.png')
          .writeAsBytesSync(png);
      store.folders.addAll([
        LibraryFolder(id: 'parent', name: 'Reactions'),
        LibraryFolder(id: 'child', name: 'Cheers', parentId: 'parent'),
      ]);
      store.items.addAll([
        LibraryItem(
          id: 'loose',
          name: 'Loose',
          filename: 'loose.png',
          kind: 'sticker',
        ),
        LibraryItem(
          id: 'nested',
          name: 'Nested',
          filename: 'nested.png',
          kind: 'sticker',
          folderId: 'child',
        ),
      ]);
      await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('folder-card-parent')), findsOneWidget);
      expect(find.text('Loose'), findsOneWidget);
      expect(find.text('Nested'), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('item-card-loose'))),
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('folder-card-parent'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.items.first.folderId, 'parent');
      await tester.tap(find.byKey(const ValueKey('folder-card-parent')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-card-child')), findsOneWidget);
      expect(find.text('Loose'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-card-child')));
      await tester.pumpAndSettle();
      expect(find.text('Nested'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('bulk selection honors Shift and Ctrl and applies a tag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    store.folders.add(LibraryFolder(id: 'destination', name: 'Destination'));
    final media = Directory.systemTemp.createTempSync('memlib-select-media-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    for (var i = 0; i < 4; i++) {
      store.items.add(
        LibraryItem(
          id: 'item$i',
          name: 'Item $i',
          filename: 'sample.png',
          kind: 'sticker',
        ),
      );
    }
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item0')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const ValueKey('select-item2')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byKey(const ValueKey('select-item1')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search or create a tag'),
      'funny',
    );
    await tester.pump();
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(store.items[0].tags, ['funny']);
    expect(store.items[1].tags, isEmpty);
    expect(store.items[2].tags, ['funny']);

    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Destination'),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.items[0].folderId, 'destination');
    expect(store.items[2].folderId, 'destination');
    expect(find.text('2 selected'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('folder-card-destination')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item0')));
    await tester.tap(find.byKey(const ValueKey('select-item2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.items.map((item) => item.id), isNot(contains('item0')));
    expect(store.items.map((item) => item.id), isNot(contains('item2')));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('dragging a selected item moves the whole selection', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    store.folders.add(LibraryFolder(id: 'destination', name: 'Destination'));
    final media = Directory.systemTemp.createTempSync('memlib-drag-media-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    for (var i = 0; i < 3; i++) {
      store.items.add(
        LibraryItem(
          id: 'item$i',
          name: 'Item $i',
          filename: 'sample.png',
          kind: 'sticker',
        ),
      );
    }
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item1')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    final source = tester.getCenter(
      find.byKey(const ValueKey('item-card-item0')),
    );
    final target = tester.getCenter(
      find.byKey(const ValueKey('sidebar-folder-destination')),
    );
    final gesture = await tester.startGesture(
      source,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(find.text('2 items'), findsWidgets);
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.items[0].folderId, 'destination');
    expect(store.items[1].folderId, 'destination');
    expect(store.items[2].folderId, isNull);
    expect(find.text('2 selected'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('select-item2')));
    await tester.pumpAndSettle();
    final remaining = tester.getCenter(
      find.byKey(const ValueKey('item-card-item2')),
    );
    final root = tester.getCenter(
      find.widgetWithText(ListTile, 'Library root'),
    );
    final rejected = await tester.startGesture(
      remaining,
      kind: PointerDeviceKind.mouse,
    );
    await rejected.moveBy(const Offset(-30, 0));
    await tester.pump();
    await rejected.moveTo(root);
    await tester.pump();
    await rejected.up();
    await tester.pumpAndSettle();
    expect(store.items[2].folderId, isNull);
    expect(find.text('1 selected'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  }, skip: !Platform.isWindows);

  testWidgets('tag filter searches existing tags across folders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    store.folders.add(LibraryFolder(id: 'other', name: 'Other'));
    final media = Directory.systemTemp.createTempSync('memlib-tags-media-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    store.items.addAll([
      LibraryItem(
        id: 'one',
        name: 'Cat',
        filename: 'sample.png',
        kind: 'sticker',
        tags: ['Funny', 'Animal'],
        folderId: 'other',
      ),
      LibraryItem(
        id: 'two',
        name: 'Dog',
        filename: 'sample.png',
        kind: 'sticker',
        tags: ['Animal'],
      ),
    ]);
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search tags'),
      'fun',
    );
    await tester.pumpAndSettle();
    expect(find.text('Funny'), findsOneWidget);
    expect(find.text('Animal'), findsNothing);
    await tester.tap(find.text('Funny'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Cat'), findsOneWidget);
    expect(find.text('Dog'), findsNothing);
    expect(find.text('Tags (1)'), findsOneWidget);
  }, skip: !Platform.isWindows);

  testWidgets('add tag offers existing tags to selected items', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    final media = Directory.systemTemp.createTempSync('memlib-tags-media-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    store.items.addAll([
      LibraryItem(
        id: 'one',
        name: 'First',
        filename: 'sample.png',
        kind: 'sticker',
      ),
      LibraryItem(
        id: 'two',
        name: 'Second',
        filename: 'sample.png',
        kind: 'sticker',
        tags: ['Funny'],
      ),
    ]);
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-one')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    expect(find.text('Existing tags'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Funny'),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.items[0].tags, ['Funny']);
  }, skip: !Platform.isWindows);

  testWidgets('long press and drag selects adjacent items on mobile', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    final media = Directory.systemTemp.createTempSync('memlib-touch-select-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    for (var i = 0; i < 4; i++) {
      store.items.add(
        LibraryItem(
          id: 'item$i',
          name: 'Item $i',
          filename: 'sample.png',
          kind: 'sticker',
        ),
      );
    }
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('item-card-item0'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1 selected'), findsOneWidget);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('item-card-item1'))),
    );
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  }, skip: !Platform.isWindows);

  testWidgets('mobile drag handle moves selected items and clears selection', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryStore();
    store.folders.add(LibraryFolder(id: 'destination', name: 'Destination'));
    final media = Directory.systemTemp.createTempSync('memlib-touch-drag-');
    store.media = media;
    addTearDown(() => media.deleteSync(recursive: true));
    File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
      ),
    );
    for (var i = 0; i < 2; i++) {
      store.items.add(
        LibraryItem(
          id: 'item$i',
          name: 'Item $i',
          filename: 'sample.png',
          kind: 'sticker',
        ),
      );
    }
    await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-item1')));
    await tester.pumpAndSettle();
    final handle = find.descendant(
      of: find.byKey(const ValueKey('item-card-item0')),
      matching: find.byTooltip('Drag selected items to a folder'),
    );
    final source = tester.getCenter(handle);
    final target = tester.getCenter(
      find.byKey(const ValueKey('folder-card-destination')),
    );
    final gesture = await tester.startGesture(source);
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      store.items.map((item) => item.folderId),
      everyElement('destination'),
    );
    expect(find.text('2 selected'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  }, skip: !Platform.isWindows);

  testWidgets(
    'Windows quick picker opens without chrome and closes with Escape',
    (tester) async {
      final store = LibraryStore();
      await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.bolt));
      await tester.pumpAndSettle();
      expect(find.text('Search items and tags'), findsOneWidget);
      expect(
        find.text(
          'Type to search   ·   Arrow keys to move   ·   Enter to paste   ·   Esc to close',
        ),
        findsOneWidget,
      );
      expect(find.byType(AppBar), findsNothing);
      await tester.tap(find.text('GIPHY'));
      await tester.pumpAndSettle();
      expect(find.text('Search GIPHY'), findsOneWidget);
      expect(find.text('Add a GIPHY API key to search'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'arrow navigation scrolls to a picker item beyond the built grid',
    (tester) async {
      final store = LibraryStore();
      final media = Directory.systemTemp.createTempSync('memlib-picker-media-');
      store.media = media;
      addTearDown(() => media.deleteSync(recursive: true));
      File('${media.path}${Platform.pathSeparator}sample.png').writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9hQ4sAAAAASUVORK5CYII=',
        ),
      );
      for (var i = 0; i < 40; i++) {
        store.items.add(
          LibraryItem(
            id: 'item$i',
            name: 'Item $i',
            filename: 'sample.png',
            kind: 'sticker',
          ),
        );
      }
      await tester.pumpWidget(MemlibApp(store: store, enableTray: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.bolt));
      await tester.pumpAndSettle();
      final distant = find.text('Item 20');
      expect(distant, findsNothing);

      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(distant, findsOneWidget);
      final viewport = tester.getRect(find.byType(GridView).first);
      final selected = tester.getRect(distant);
      expect(selected.top, greaterThanOrEqualTo(viewport.top));
      expect(selected.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  testWidgets('quick picker can save and favourite a GIPHY result', (
    tester,
  ) async {
    final store = _MemoryStore();
    final service = GiphyService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/search')) {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'abc',
                  'title': 'Wave',
                  'images': {
                    'fixed_width_small': {
                      'url': 'https://example.test/preview.gif',
                    },
                    'original': {'url': 'https://example.test/full.gif'},
                  },
                },
              ],
              'pagination': {'count': 1, 'total_count': 1},
            }),
            200,
          );
        }
        return http.Response.bytes([71, 73, 70, 56, 57, 97], 200);
      }),
    );
    await tester.pumpWidget(
      MemlibApp(store: store, enableTray: false, giphyService: service),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GIPHY'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'wave');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Save to library'), findsOneWidget);
    expect(find.byTooltip('Add favourite'), findsOneWidget);
    await tester.tap(find.byTooltip('Save to library'));
    await tester.pumpAndSettle();
    expect(store.items.single.sourceId, 'abc');
    expect(find.byTooltip('Saved to library'), findsOneWidget);
    await tester.tap(find.byTooltip('Add favourite'));
    await tester.pumpAndSettle();
    expect(store.items.single.favorite, isTrue);
    expect(find.byTooltip('Remove favourite'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows || !GiphyService.librarySavesEnabled);

  testWidgets('arrow navigation scrolls through distant GIPHY results', (
    tester,
  ) async {
    final service = GiphyService(
      apiKey: 'test-key',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'data': [
              for (var i = 0; i < 24; i++)
                {
                  'id': 'gif$i',
                  'title': 'Result $i',
                  'images': {
                    'fixed_width_small': {
                      'url': 'https://example.test/preview$i.gif',
                    },
                    'original': {'url': 'https://example.test/full$i.gif'},
                  },
                },
            ],
            'pagination': {'count': 24, 'total_count': 24},
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MemlibApp(
        store: LibraryStore(),
        enableTray: false,
        giphyService: service,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GIPHY'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'wave');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Result 23'), findsNothing);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(find.text('Result 23'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
