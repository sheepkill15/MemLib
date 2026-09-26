import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/library_store.dart';
import 'package:memlib/openverse_panel.dart';
import 'package:memlib/openverse_service.dart';

void main() {
  testWidgets('star saves an Openverse GIF directly to favourites', (
    tester,
  ) async {
    final sandbox = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('memlib-openverse-ui-'),
    ))!;
    final store = LibraryStore();
    store.root = sandbox;
    store.media = Directory('${sandbox.path}${Platform.pathSeparator}media');
    await tester.runAsync(() => store.media.create());
    final service = OpenverseService(
      client: MockClient((request) async {
        if (request.url.host == 'api.openverse.org') {
          return http.Response(
            jsonEncode({
              'next': null,
              'results': [
                {
                  'id': 'one',
                  'title': 'Wave',
                  'url': 'https://example.com/wave.gif',
                  'thumbnail': 'https://example.com/thumb.gif',
                  'foreign_landing_url': 'https://example.com/source',
                  'license': 'cc0',
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes([71, 73, 70, 56, 57, 97], 200);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpenversePanel(store: store, searchService: service),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'wave');
    await tester.tap(find.text('Search'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.byTooltip('Save as favourite')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(store.items.single.name, 'Wave');
    expect(store.items.single.favorite, isTrue);
    expect(store.items.single.sourcePage, 'https://example.com/source');
    expect(
      await tester.runAsync(
        () => store.fileFor(store.items.single).readAsBytes(),
      ),
      [71, 73, 70, 56, 57, 97],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    store.dispose();
    await tester.runAsync(() => sandbox.delete(recursive: true));
  });
}
