import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const _imageLimit = 30 * 1024 * 1024;
const _zipLimit = 100 * 1024 * 1024;

/// Splits dropped or pasted text into importable sources: local file paths and
/// http(s) or data: links. Returns an empty list unless every line is one, so
/// ordinary text is never mistaken for an import.
List<String> parseLinkedSources(String text) {
  final sources = <String>[];
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.length > 1 &&
        ((line.startsWith('"') && line.endsWith('"')) ||
            (line.startsWith('<') && line.endsWith('>')))) {
      line = line.substring(1, line.length - 1).trim();
    }
    final source = _source(line);
    if (source == null) return const [];
    sources.add(source);
  }
  return sources;
}

String? _source(String line) {
  if (RegExp(r'^([a-zA-Z]:[\\/]|\\\\)').hasMatch(line)) return line;
  final uri = Uri.tryParse(line);
  if (uri == null) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' when uri.host.isNotEmpty => uri.toString(),
    'file' => _filePath(uri),
    'data' when uri.data?.mimeType.startsWith('image/') == true => line,
    _ => null,
  };
}

String? _filePath(Uri uri) {
  try {
    return uri.toFilePath(windows: Platform.isWindows);
  } catch (_) {
    return null;
  }
}

/// Whether [source] from [parseLinkedSources] must be fetched rather than read
/// from disk.
bool isRemoteSource(String source) =>
    RegExp(r'^(https?|data):', caseSensitive: false).hasMatch(source);

class LinkedMedia {
  const LinkedMedia(this.bytes, {required this.name, required this.extension});

  final Uint8List bytes;
  final String name;

  /// One of png, gif, jpg, webp or zip, detected from the content itself.
  final String extension;
}

/// Downloads an image or ZIP behind [source], an http(s) or data: link.
Future<LinkedMedia> fetchLinkedMedia(http.Client client, String source) async {
  final uri = Uri.parse(source);
  final Uint8List bytes;
  if (uri.scheme.toLowerCase() == 'data') {
    bytes = uri.data!.contentAsBytes();
  } else {
    final response = await client.send(http.Request('GET', uri));
    if (response.statusCode != 200) {
      throw HttpException('Could not download link: ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > _zipLimit) {
        throw const FormatException('Linked file exceeds the 100 MB limit');
      }
      builder.add(chunk);
    }
    bytes = builder.takeBytes();
  }
  final extension = sniffMediaExtension(bytes);
  if (extension == null) {
    throw const FormatException('Link is not a PNG, GIF, JPEG, WebP, or ZIP');
  }
  if (extension != 'zip' && bytes.length > _imageLimit) {
    throw const FormatException('Images must be under 30 MB');
  }
  return LinkedMedia(bytes, name: _nameFor(uri), extension: extension);
}

String _nameFor(Uri uri) {
  if (uri.scheme.toLowerCase() == 'data') return 'Pasted image';
  final segment = uri.pathSegments.lastWhere(
    (segment) => segment.isNotEmpty,
    orElse: () => '',
  );
  final name = segment.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
  return name.isEmpty ? uri.host : name;
}

/// Detects a supported media type from its leading bytes.
String? sniffMediaExtension(Uint8List bytes) {
  bool startsWith(List<int> prefix, [int offset = 0]) {
    if (bytes.length < offset + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[offset + i] != prefix[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'png';
  }
  if (startsWith('GIF8'.codeUnits)) return 'gif';
  if (startsWith([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
    return 'webp';
  }
  if (startsWith([0x50, 0x4B, 0x03, 0x04])) return 'zip';
  return null;
}
