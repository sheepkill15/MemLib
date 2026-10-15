import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memlib/link_import.dart';

final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, //
]);

void main() {
  test('parses links, file URLs and quoted paths', () {
    expect(
      parseLinkedSources(
        'https://media.example.com/cats/happy.gif\r\n'
        '"C:\\Users\\me\\Pictures\\cat.png"\n'
        '# comment from text/uri-list\n'
        '<http://example.com/a.webp>',
      ),
      [
        'https://media.example.com/cats/happy.gif',
        r'C:\Users\me\Pictures\cat.png',
        'http://example.com/a.webp',
      ],
    );
    expect(parseLinkedSources(r'\\server\share\x.jpg'), [
      r'\\server\share\x.jpg',
    ]);
    expect(parseLinkedSources('file:///tmp/x.png').single, endsWith('x.png'));
  });

  test('ignores ordinary text', () {
    expect(parseLinkedSources('funny cat'), isEmpty);
    expect(parseLinkedSources('https://example.com/a.gif\nhello'), isEmpty);
    expect(parseLinkedSources('mailto:me@example.com'), isEmpty);
    expect(parseLinkedSources(''), isEmpty);
  });

  test('sniffs supported media types', () {
    expect(sniffMediaExtension(_png), 'png');
    expect(sniffMediaExtension(ascii.encode('GIF89a...')), 'gif');
    expect(
      sniffMediaExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0])),
      'jpg',
    );
    expect(
      sniffMediaExtension(ascii.encode('RIFF\x00\x00\x00\x00WEBPVP8 ')),
      'webp',
    );
    expect(sniffMediaExtension(ascii.encode('PK\x03\x04')), 'zip');
    expect(sniffMediaExtension(ascii.encode('<!doctype html>')), isNull);
  });

  test('downloads linked images and names them after the URL', () async {
    final client = MockClient((request) async {
      return request.url.path.endsWith('.png')
          ? http.Response.bytes(_png, 200)
          : http.Response('<html></html>', 200);
    });
    final media = await fetchLinkedMedia(
      client,
      'https://example.com/memes/Big%20Cat.png?size=large',
    );
    expect(media.extension, 'png');
    expect(media.name, 'Big Cat');
    await expectLater(
      fetchLinkedMedia(client, 'https://example.com/page'),
      throwsFormatException,
    );
  });

  test('decodes data: image links', () async {
    final source = 'data:image/png;base64,${base64Encode(_png)}';
    expect(parseLinkedSources(source), [source]);
    expect(isRemoteSource(source), isTrue);
    final media = await fetchLinkedMedia(
      MockClient((_) async => throw 1),
      source,
    );
    expect(media.extension, 'png');
  });
}
