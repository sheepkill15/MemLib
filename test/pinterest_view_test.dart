import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/library_store.dart';
import 'package:memlib/pinterest_service.dart';
import 'package:memlib/pinterest_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;
  late LibraryStore store;
  final requests = <String>[];

  Map<String, dynamic> pin(String id, String title) => {
    'id': id,
    'title': title,
    'media': {
      'media_type': 'image',
      'images': {
        '600x': {'url': 'https://i.pinimg.com/600x/$id.jpg'},
        'originals': {'url': 'https://i.pinimg.com/originals/$id.jpg'},
      },
    },
  };

  PinterestService service() => PinterestService(
    functionUrl: 'https://example.supabase.co/functions/v1/pinterest-oauth',
    client: MockClient((request) async {
      requests.add(request.url.path);
      expect(request.headers['authorization'], 'Bearer access');
      final body = switch (request.url.path) {
        '/v5/boards' => {
          'items': [
            {'id': 'b1', 'name': 'Reactions', 'pin_count': 2},
          ],
          'bookmark': null,
        },
        '/v5/boards/b1/pins' => {
          'items': [pin('p1', 'Wave'), pin('p2', 'Shrug')],
          'bookmark': null,
        },
        _ => throw StateError('Unexpected ${request.url}'),
      };
      return http.Response(jsonEncode(body), 200);
    }),
  );

  setUp(() async {
    requests.clear();
    SharedPreferences.setMockInitialValues({
      'pinterest_session': jsonEncode({
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAt': DateTime.now()
            .add(const Duration(days: 20))
            .millisecondsSinceEpoch,
        'username': 'simon',
      }),
    });
    sandbox = await Directory.systemTemp.createTemp('memlib-pinterest-test-');
    store = LibraryStore();
    store.root = sandbox;
    store.media = Directory('${sandbox.path}${Platform.pathSeparator}media');
    await store.media.create();
  });

  tearDown(() async {
    store.dispose();
    await sandbox.delete(recursive: true);
  });

  Future<List<String>> pump(
    WidgetTester tester,
    PinterestService service,
  ) async {
    final messages = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinterestView(
            service: service,
            store: store,
            folderId: null,
            onUse: (_) async {},
            onMessage: messages.add,
          ),
        ),
      ),
    );
    return messages;
  }

  /// Lets real I/O (the library index on disk) finish between frames.
  Future<void> settle(WidgetTester tester, [bool Function()? until]) async {
    for (var i = 0; i < 40 && (i < 6 || until?.call() == false); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  testWidgets('builds without PINTEREST_ENABLED show it as unavailable', (
    tester,
  ) async {
    await pump(tester, service());
    await settle(tester);
    expect(find.text('Pinterest is unavailable in this build'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('connected session lists boards, pins and adds a board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messages = await pump(tester, _EnabledService(service()));
    await settle(tester);
    expect(find.text('Your boards'), findsOneWidget);
    expect(find.text('Pinterest · @simon'), findsOneWidget);
    expect(find.textContaining('Reactions'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pinterest-board-b1')));
    await settle(tester);
    expect(find.text('Wave'), findsOneWidget);
    expect(find.text('Shrug'), findsOneWidget);

    await tester.tap(find.byTooltip('Save to library').first);
    await settle(tester, () => messages.isNotEmpty);
    final saved = store.itemBySource('pinterest', 'p1')!;
    expect(saved.isLinked, isTrue);
    expect(saved.mediaUrl, 'https://i.pinimg.com/originals/p1.jpg');
    expect(saved.sourcePage, 'https://www.pinterest.com/pin/p1/');
    expect(messages.last, 'Saved to your library');

    await tester.tap(find.text('Add board to library'));
    await settle(tester, () => messages.last.startsWith('Added'));
    expect(store.folders.single.name, 'Reactions');
    expect(store.items, hasLength(2));
    expect(
      store.itemBySource('pinterest', 'p2')!.folderId,
      store.folders.single.id,
    );
    expect(messages.last, 'Added 1 pin to Reactions');
    final media = await tester.runAsync(() => store.media.list().toList());
    expect(media, isEmpty);
  });
}

/// Builds without PINTEREST_ENABLED still exercise the connected view.
class _EnabledService extends PinterestService {
  _EnabledService(PinterestService inner)
    : _inner = inner,
      super(functionUrl: inner.functionUrl);
  final PinterestService _inner;

  @override
  bool get configured => true;
  @override
  bool get connected => _inner.connected;
  @override
  String? get username => _inner.username;
  @override
  Future<void> load() async {
    await _inner.load();
    notifyListeners();
  }

  @override
  Future<PinterestPage<PinterestBoard>> boards({String? bookmark}) =>
      _inner.boards(bookmark: bookmark);
  @override
  Future<PinterestPage<PinterestPin>> pins(
    String boardId, {
    String? bookmark,
    int pageSize = 50,
  }) => _inner.pins(boardId, bookmark: bookmark, pageSize: pageSize);
}
