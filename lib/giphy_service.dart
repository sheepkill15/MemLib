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

class GiphyService {
  static const windowsKey = String.fromEnvironment('GIPHY_WINDOWS_KEY');
  static const androidKey = String.fromEnvironment('GIPHY_ANDROID_KEY');
  String get key => Platform.isWindows ? windowsKey : androidKey;
  bool get configured => key.isNotEmpty;

  Future<List<GiphyResult>> search(String query, {bool stickers = false}) async {
    if (!configured || query.trim().isEmpty) return [];
    final uri = Uri.https('api.giphy.com', '/v1/${stickers ? 'stickers' : 'gifs'}/search', {
      'api_key': key,
      'q': query.trim(),
      'limit': '24',
      'rating': 'pg',
    });
    final response = await http.get(uri);
    if (response.statusCode != 200) throw HttpException('GIPHY search failed: ${response.statusCode}');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (data['data'] as List<dynamic>).map((raw) {
      final entry = raw as Map<String, dynamic>;
      final images = entry['images'] as Map<String, dynamic>;
      final preview = (images['fixed_width_small'] ?? images['fixed_width']) as Map<String, dynamic>;
      final original = images['original'] as Map<String, dynamic>;
      return GiphyResult(
        id: entry['id'] as String,
        title: entry['title'] as String? ?? 'GIF',
        previewUrl: preview['url'] as String,
        gifUrl: original['url'] as String,
      );
    }).toList();
  }

  Future<Uint8List> fetchForShare(GiphyResult result) async {
    final response = await http.get(Uri.parse(result.gifUrl));
    if (response.statusCode != 200) throw HttpException('Could not load GIF: ${response.statusCode}');
    return response.bodyBytes;
  }
}
