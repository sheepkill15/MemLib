import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class OpenverseResult {
  const OpenverseResult({required this.id, required this.title, required this.previewUrl, required this.mediaUrl, required this.sourcePage, required this.licenseLabel});
  final String id;
  final String title;
  final String previewUrl;
  final String mediaUrl;
  final String sourcePage;
  final String licenseLabel;
}

class OpenversePage {
  const OpenversePage(this.results, this.hasMore);
  final List<OpenverseResult> results;
  final bool hasMore;
}

class OpenverseDownload {
  const OpenverseDownload(this.bytes, this.extension);
  final Uint8List bytes;
  final String extension;
}

class OpenverseService {
  OpenverseService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<OpenversePage> search(String query, {required bool stickers, int page = 1}) async {
    if (query.trim().isEmpty) return const OpenversePage([], false);
    final uri = Uri.https('api.openverse.org', '/v1/images/', {
      'q': stickers ? '${query.trim()} sticker' : query.trim(),
      'extension': stickers ? 'png,webp' : 'gif',
      'license': 'cc0,pdm',
      'page_size': '20',
      'page': '$page',
    });
    final response = await _client.get(uri, headers: {'User-Agent': 'Memlib/0.1 (personal media library)'});
    if (response.statusCode != 200) throw HttpException('Openverse search failed: ${response.statusCode}');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final results = <OpenverseResult>[];
    for (final raw in data['results'] as List<dynamic>? ?? []) {
      final row = raw as Map<String, dynamic>;
      final license = row['license'] as String?;
      if (license != 'cc0' && license != 'pdm') continue;
      final media = Uri.tryParse(row['url'] as String? ?? '');
      final preview = Uri.tryParse(row['thumbnail'] as String? ?? '');
      final source = Uri.tryParse(row['foreign_landing_url'] as String? ?? '');
      if (media?.scheme != 'https' || preview?.scheme != 'https' || source?.scheme != 'https') continue;
      results.add(OpenverseResult(
        id: row['id'] as String,
        title: (row['title'] as String?)?.trim().isNotEmpty == true ? (row['title'] as String).trim() : 'Untitled',
        previewUrl: preview.toString(),
        mediaUrl: media.toString(),
        sourcePage: source.toString(),
        licenseLabel: license == 'cc0' ? 'CC0' : 'Public domain',
      ));
    }
    return OpenversePage(results, data['next'] != null);
  }

  Future<OpenverseDownload> download(OpenverseResult result) async {
    final uri = Uri.tryParse(result.mediaUrl);
    if (uri?.scheme != 'https') throw const FormatException('Media must use HTTPS');
    final response = await _client.get(uri!);
    if (response.statusCode != 200) throw HttpException('Could not download image: ${response.statusCode}');
    final bytes = response.bodyBytes;
    if (bytes.length > 20 * 1024 * 1024) throw const FormatException('Image exceeds the 20 MB library limit');
    final extension = _detectExtension(bytes);
    if (extension == null) throw const FormatException('The downloaded file is not a supported image');
    return OpenverseDownload(bytes, extension);
  }

  String? _detectExtension(Uint8List bytes) {
    if (bytes.length >= 6 && ascii.decode(bytes.sublist(0, 3)) == 'GIF') return 'gif';
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47) return 'png';
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return 'jpg';
    if (bytes.length >= 12 && ascii.decode(bytes.sublist(0, 4)) == 'RIFF' && ascii.decode(bytes.sublist(8, 12)) == 'WEBP') return 'webp';
    return null;
  }

  void dispose() => _client.close();
}
