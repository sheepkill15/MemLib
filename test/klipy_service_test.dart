import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/giphy_service.dart';
import 'package:memlib/klipy_service.dart';

void main() {
  test(
    'KLIPY search parses media, skips ads, pages, and reports shares',
    () async {
      final requests = <http.Request>[];
      final service = KlipyService(
        apiKey: 'test-key',
        customerId: 'user-one',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/search')) {
            return http.Response(
              jsonEncode({
                'result': true,
                'data': {
                  'data': [
                    {
                      'id': 1,
                      'slug': 'wave',
                      'title': 'Wave',
                      'type': 'gif',
                      'file': {
                        'sm': {
                          'gif': {
                            'url': 'https://static.klipy.com/preview.gif',
                          },
                        },
                        'md': {
                          'gif': {'url': 'https://static.klipy.com/full.gif'},
                        },
                      },
                    },
                    {'type': 'ad'},
                    {'slug': 'broken', 'file': {}},
                  ],
                  'has_next': request.url.queryParameters['page'] == '1',
                },
              }),
              200,
            );
          }
          if (request.method == 'POST') {
            return http.Response('{"result":true}', 200);
          }
          return http.Response.bytes('GIF89a'.codeUnits, 200);
        }),
      );

      final first = await service.search('hello', stickers: true);
      expect(first.items.single.id, 'wave');
      expect(first.items.single.gifUrl, 'https://static.klipy.com/full.gif');
      expect(first.nextOffset, 1);
      expect(requests.first.url.path, '/api/v1/test-key/stickers/search');
      expect(requests.first.url.queryParameters['customer_id'], 'user-one');
      final second = await service.search(
        'hello',
        stickers: true,
        offset: first.nextOffset!,
      );
      expect(second.nextOffset, isNull);
      expect(
        await service.fetchForShare(first.items.single),
        'GIF89a'.codeUnits,
      );
      await service.track(first.items.single, GiphyAction.send);
      expect(requests.last.method, 'POST');
      expect(requests.last.url.path, '/api/v1/test-key/stickers/share/wave');
      expect(jsonDecode(requests.last.body)['q'], 'hello');
      service.dispose();
    },
  );
}
