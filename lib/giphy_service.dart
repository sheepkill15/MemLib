import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum GiphyAction { load, click, send }

class GiphyResult {
  const GiphyResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.gifUrl,
    this.pageUrl,
    this.onloadUrl,
    this.onclickUrl,
    this.onsentUrl,
    this.slug,
    this.stickers = false,
    this.searchQuery,
  });
  final String id;
  final String title;
  final String previewUrl;
  final String gifUrl;
  final String? pageUrl;
  final String? onloadUrl;
  final String? onclickUrl;
  final String? onsentUrl;
  final String? slug;
  final bool stickers;
  final String? searchQuery;
}

class GiphyPage {
  const GiphyPage({required this.items, required this.nextOffset});
  final List<GiphyResult> items;
  final int? nextOffset;
}

class GiphyService {
  static const librarySavesEnabled = bool.fromEnvironment(
    'GIPHY_LIBRARY_SAVES_ENABLED',
  );
  // The public override is used by tests; the persisted value stays private.
  // ignore: prefer_initializing_formals
  GiphyService({http.Client? client, String? apiKey, this._customerId})
    : _client = client ?? http.Client(),
      _keyOverride = apiKey;

  static const windowsKey = String.fromEnvironment('GIPHY_WINDOWS_KEY');
  static const androidKey = String.fromEnvironment('GIPHY_ANDROID_KEY');
  final http.Client _client;
  final String? _keyOverride;
  String? _customerId;
  String get key =>
      _keyOverride ?? (Platform.isWindows ? windowsKey : androidKey);
  bool get configured => key.isNotEmpty;

  Future<GiphyPage> search(
    String query, {
    bool stickers = false,
    int offset = 0,
  }) async {
    if (!configured || query.trim().isEmpty) {
      return const GiphyPage(items: [], nextOffset: null);
    }
    final uri = Uri.https(
      'api.giphy.com',
      '/v1/${stickers ? 'stickers' : 'gifs'}/search',
      {
        'api_key': key,
        'q': query.trim(),
        'limit': '24',
        'offset': '$offset',
        'rating': 'pg',
      },
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw HttpException('GIPHY search failed: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = <GiphyResult>[];
    for (final raw in data['data'] as List<dynamic>? ?? []) {
      final entry = raw as Map<String, dynamic>;
      final images = entry['images'] as Map<String, dynamic>? ?? {};
      final preview =
          (images['fixed_width_small'] ?? images['fixed_width'])
              as Map<String, dynamic>?;
      final original = images['original'] as Map<String, dynamic>?;
      final previewUrl = preview?['url'] as String?;
      final gifUrl = original?['url'] as String?;
      if (previewUrl == null || gifUrl == null) continue;
      final analytics = entry['analytics'] as Map<String, dynamic>? ?? {};
      items.add(
        GiphyResult(
          id: entry['id'] as String,
          title: entry['title'] as String? ?? 'GIF',
          previewUrl: previewUrl,
          gifUrl: gifUrl,
          pageUrl:
              (entry['url'] as String?)?.startsWith('https://giphy.com/') ==
                  true
              ? entry['url'] as String
              : 'https://giphy.com/gifs/${entry['id']}',
          onloadUrl:
              (analytics['onload'] as Map<String, dynamic>?)?['url'] as String?,
          onclickUrl:
              (analytics['onclick'] as Map<String, dynamic>?)?['url']
                  as String?,
          onsentUrl:
              (analytics['onsent'] as Map<String, dynamic>?)?['url'] as String?,
        ),
      );
    }
    final pagination = data['pagination'] as Map<String, dynamic>? ?? {};
    final count = pagination['count'] as int? ?? items.length;
    final total = pagination['total_count'] as int? ?? offset + count;
    final next = offset + count;
    return GiphyPage(
      items: items,
      nextOffset: count > 0 && next < total && next < 5000 ? next : null,
    );
  }

  Future<Uint8List> fetchForShare(GiphyResult result) async {
    final uri = Uri.parse(result.gifUrl);
    if (uri.scheme != 'https') {
      throw const FormatException('GIPHY media must use HTTPS');
    }
    final response = await _client.send(http.Request('GET', uri));
    if (response.statusCode != 200) {
      throw HttpException('Could not load GIF: ${response.statusCode}');
    }
    const limit = 20 * 1024 * 1024;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('GIF exceeds the 20 MB limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> track(GiphyResult result, GiphyAction action) async {
    final url = switch (action) {
      GiphyAction.load => result.onloadUrl,
      GiphyAction.click => result.onclickUrl,
      GiphyAction.send => result.onsentUrl,
    };
    if (url == null) return;
    final base = Uri.tryParse(url);
    if (base == null ||
        base.scheme != 'https' ||
        base.host != 'giphy-analytics.giphy.com') {
      return;
    }
    try {
      final id = await _getCustomerId();
      await _client.get(
        base.replace(
          queryParameters: {
            ...base.queryParameters,
            'customer_id': id,
            'ts': '${DateTime.now().millisecondsSinceEpoch}',
          },
        ),
      );
    } catch (_) {
      /* Reporting must not interrupt selecting a GIF. */
    }
  }

  Future<String> _getCustomerId() async {
    if (_customerId != null) return _customerId!;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('giphy_customer_id');
    if (existing != null) return _customerId = existing;
    final created = const Uuid().v4();
    await prefs.setString('giphy_customer_id', created);
    return _customerId = created;
  }

  void dispose() => _client.close();
}
