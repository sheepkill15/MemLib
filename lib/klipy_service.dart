import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'giphy_service.dart';

/// KLIPY search, sharing, and downloads gated by the existing save permission.
class KlipyService extends GiphyService {
  KlipyService({http.Client? client, String? apiKey, this._customerId})
    : _client = client ?? http.Client(),
      _keyOverride = apiKey;

  static const windowsKey = String.fromEnvironment('KLIPY_WINDOWS_KEY');
  static const androidKey = String.fromEnvironment('KLIPY_ANDROID_KEY');
  final http.Client _client;
  final String? _keyOverride;
  String? _customerId;

  @override
  String get key =>
      _keyOverride ?? (Platform.isWindows ? windowsKey : androidKey);

  @override
  bool get configured => key.isNotEmpty;

  @override
  Future<GiphyPage> search(
    String query, {
    bool stickers = false,
    int offset = 0,
  }) async {
    if (!configured || query.trim().isEmpty) {
      return const GiphyPage(items: [], nextOffset: null);
    }
    final page = offset + 1;
    final uri = Uri.https(
      'api.klipy.com',
      '/api/v1/${Uri.encodeComponent(key)}/${stickers ? 'stickers' : 'gifs'}/search',
      {
        'page': '$page',
        'per_page': '24',
        'q': query.trim(),
        'customer_id': await _getCustomerId(),
        'content_filter': 'medium',
        'format_filter': 'gif',
      },
    );
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw HttpException('KLIPY search failed: ${response.statusCode}');
    }
    final root = jsonDecode(response.body) as Map<String, dynamic>;
    if (root['result'] != true) {
      throw const FormatException('KLIPY search failed');
    }
    final data = root['data'] as Map<String, dynamic>? ?? {};
    final items = <GiphyResult>[];
    for (final raw in data['data'] as List<dynamic>? ?? []) {
      if (raw is! Map<String, dynamic> || raw['type'] == 'ad') continue;
      final file = raw['file'] as Map<String, dynamic>? ?? {};
      String? gif(String size) =>
          ((file[size] as Map<String, dynamic>?)?['gif']
                  as Map<String, dynamic>?)?['url']
              as String?;
      final preview = gif('sm') ?? gif('xs') ?? gif('md');
      final full = gif('md') ?? gif('hd');
      final slug = raw['slug']?.toString();
      if (slug == null ||
          slug.isEmpty ||
          preview == null ||
          full == null ||
          Uri.tryParse(preview)?.scheme != 'https' ||
          Uri.tryParse(full)?.scheme != 'https') {
        continue;
      }
      items.add(
        GiphyResult(
          id: slug,
          title: raw['title']?.toString() ?? 'GIF',
          previewUrl: preview,
          gifUrl: full,
          pageUrl: full,
          slug: slug,
          stickers: stickers,
          searchQuery: query.trim(),
        ),
      );
    }
    return GiphyPage(
      items: items,
      nextOffset: data['has_next'] == true ? page : null,
    );
  }

  @override
  Future<Uint8List> fetchForShare(GiphyResult result) async {
    final uri = Uri.parse(result.gifUrl);
    if (uri.scheme != 'https') {
      throw const FormatException('KLIPY media must use HTTPS');
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

  @override
  Future<void> track(GiphyResult result, GiphyAction action) async {
    if (action != GiphyAction.send || result.slug == null || !configured) {
      return;
    }
    try {
      await _client.post(
        Uri.https(
          'api.klipy.com',
          '/api/v1/${Uri.encodeComponent(key)}/${result.stickers ? 'stickers' : 'gifs'}/share/${Uri.encodeComponent(result.slug!)}',
        ),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'customer_id': await _getCustomerId(),
          'q': result.searchQuery ?? '',
        }),
      );
    } catch (_) {
      // Tracking does not interrupt sharing.
    }
  }

  Future<String> _getCustomerId() async {
    if (_customerId != null) return _customerId!;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('klipy_customer_id');
    if (saved != null) return _customerId = saved;
    final created = const Uuid().v4();
    await prefs.setString('klipy_customer_id', created);
    return _customerId = created;
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
