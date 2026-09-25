import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/giphy_service.dart';

void main() {
  test('GIPHY search pages results and skips entries without usable media', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      final offset = int.parse(request.url.queryParameters['offset']!);
      return http.Response(jsonEncode({
        'data': [
          {
            'id': 'result-$offset',
            'title': 'Reaction $offset',
            'images': {
              'fixed_width_small': {'url': 'https://example.com/preview.gif'},
              'original': {'url': 'https://example.com/original.gif'},
            },
          },
          {'id': 'broken', 'images': {}},
        ],
        'pagination': {'count': 2, 'total_count': 4},
      }), 200);
    });
    final service = GiphyService(client: client, apiKey: 'test-key');

    final first = await service.search('face palm', stickers: true);
    expect(first.items.map((item) => item.id), ['result-0']);
    expect(first.nextOffset, 2);
    expect(requests.first.path, '/v1/stickers/search');
    expect(requests.first.queryParameters['q'], 'face palm');

    final second = await service.search('face palm', stickers: true, offset: first.nextOffset!);
    expect(second.items.map((item) => item.id), ['result-2']);
    expect(second.nextOffset, isNull);
    service.dispose();
  });
}
