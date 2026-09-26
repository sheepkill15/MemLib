import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/openverse_service.dart';

void main() {
  test('search filters to public-domain media and preserves source details', () async {
    final service = OpenverseService(client: MockClient((request) async {
      expect(request.url.queryParameters['license'], 'cc0,pdm');
      expect(request.url.queryParameters['extension'], 'gif');
      return http.Response(jsonEncode({'next': null, 'results': [
        {'id': 'one', 'title': 'Wave', 'url': 'https://example.com/wave.gif', 'thumbnail': 'https://example.com/thumb.gif', 'foreign_landing_url': 'https://example.com/source', 'license': 'cc0'},
        {'id': 'two', 'title': 'Restricted', 'url': 'https://example.com/two.gif', 'thumbnail': 'https://example.com/two.gif', 'foreign_landing_url': 'https://example.com/two', 'license': 'by'},
      ]}), 200);
    }));
    final page = await service.search('wave', stickers: false);
    expect(page.results.single.title, 'Wave');
    expect(page.results.single.sourcePage, 'https://example.com/source');
    expect(page.results.single.licenseLabel, 'CC0');
    expect(page.hasMore, false);
    service.dispose();
  });

  test('download accepts image bytes and rejects HTML responses', () async {
    final result = OpenverseResult(id: 'one', title: 'Wave', previewUrl: 'https://example.com/thumb', mediaUrl: 'https://example.com/wave', sourcePage: 'https://example.com/source', licenseLabel: 'CC0');
    final good = OpenverseService(client: MockClient((_) async => http.Response.bytes([71, 73, 70, 56, 57, 97], 200)));
    expect((await good.download(result)).extension, 'gif');
    good.dispose();
    final bad = OpenverseService(client: MockClient((_) async => http.Response('<html>error</html>', 200)));
    await expectLater(bad.download(result), throwsFormatException);
    bad.dispose();
  });
}
