import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GiphyResult {
  const GiphyResult({required this.id, required this.title, required this.previewUrl, required this.gifUrl});
  final String id;
  final String title;
  final String previewUrl;
  final String gifUrl;
}

class GiphyPage {
  const GiphyPage({required this.items, required this.nextOffset});
  final List<GiphyResult> items;
  final int? nextOffset;
}

class GiphyService {
  GiphyService({http.Client? client, String? apiKey}) : _client = client ?? http.Client(), _keyOverride = apiKey;

  static const windowsKey = String.fromEnvironment('GIPHY_WINDOWS_KEY');
  static const androidKey = String.fromEnvironment('GIPHY_ANDROID_KEY');
  final http.Client _client;
  final String? _keyOverride;
  String get key => _keyOverride ?? (Platform.isWindows ? windowsKey : androidKey);
  bool get configured => key.isNotEmpty;

  Future<GiphyPage> search(String query, {bool stickers = false, int offset = 0}) async {
    if (!configured || query.trim().isEmpty) return const GiphyPage(items: [], nextOffset: null);
    final uri = Uri.https('api.giphy.com', '/v1/${stickers ? 'stickers' : 'gifs'}/search', {
      'api_key': key,
      'q': query.trim(),
      'limit': '24',
      'offset': '$offset',
      'rating': 'pg',
    });
    final response = await _client.get(uri);
    if (response.statusCode != 200) throw HttpException('GIPHY search failed: ${response.statusCode}');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = <GiphyResult>[];
    for (final raw in data['data'] as List<dynamic>? ?? []) {
      final entry = raw as Map<String, dynamic>;
      final images = entry['images'] as Map<String, dynamic>? ?? {};
      final preview = (images['fixed_width_small'] ?? images['fixed_width']) as Map<String, dynamic>?;
      final original = images['original'] as Map<String, dynamic>?;
      final previewUrl = preview?['url'] as String?;
      final gifUrl = original?['url'] as String?;
      if (previewUrl == null || gifUrl == null) continue;
      items.add(GiphyResult(
        id: entry['id'] as String,
        title: entry['title'] as String? ?? 'GIF',
        previewUrl: previewUrl,
        gifUrl: gifUrl,
      ));
    }
    final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
    final count = pagination['count'] as int? ?? items.length;
    final total = pagination['total_count'] as int? ?? offset + count;
    final next = offset + count;
    return GiphyPage(items: items, nextOffset: count > 0 && next < total && next < 5000 ? next : null);
  }

  Future<Uint8List> fetchForShare(GiphyResult result) async {
    final response = await _client.get(Uri.parse(result.gifUrl));
    if (response.statusCode != 200) throw HttpException('Could not load GIF: ${response.statusCode}');
    return response.bodyBytes;
  }

  void dispose() => _client.close();
}
