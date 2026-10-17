import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memlib/pinterest_service.dart';
import 'package:memlib/secret_storage.dart';

void main() {
  Map<String, dynamic> image(String url) => {
    'url': url,
    'width': 1,
    'height': 1,
  };

  test('parses an image pin into a link back to Pinterest', () {
    final pin = PinterestService.parsePin({
      'id': '987',
      'title': '  ',
      'description': 'Cat waving',
      'media': {
        'media_type': 'image',
        'images': {
          '600x': image('https://i.pinimg.com/600x/aa/cat.gif'),
          'originals': image('https://i.pinimg.com/originals/aa/cat.gif'),
        },
      },
    })!;
    expect(pin.title, 'Cat waving');
    expect(pin.previewUrl, 'https://i.pinimg.com/600x/aa/cat.gif');
    expect(pin.isGif, isTrue);
    final link = pin.toLink(favorite: true);
    expect(link.mediaUrl, 'https://i.pinimg.com/originals/aa/cat.gif');
    expect(link.kind, 'gif');
    expect(link.sourceType, 'pinterest');
    expect(link.sourceId, '987');
    expect(link.sourcePage, 'https://www.pinterest.com/pin/987/');
    expect(link.favorite, isTrue);
  });

  test('uses the first image of a carousel pin', () {
    final pin = PinterestService.parsePin({
      'id': '1',
      'title': 'Set',
      'media': {
        'media_type': 'multiple_images',
        'items': [
          {
            'images': {'1200x': image('https://i.pinimg.com/1200x/first.jpg')},
          },
        ],
      },
    })!;
    expect(pin.mediaUrl, 'https://i.pinimg.com/1200x/first.jpg');
    expect(pin.previewUrl, pin.mediaUrl);
    expect(pin.isGif, isFalse);
  });

  test('skips video pins and pins without HTTPS images', () {
    expect(
      PinterestService.parsePin({
        'id': '2',
        'media': {
          'media_type': 'video',
          'images': {'originals': image('https://i.pinimg.com/v.jpg')},
        },
      }),
      isNull,
    );
    expect(
      PinterestService.parsePin({
        'id': '3',
        'media': {
          'media_type': 'image',
          'images': {'originals': image('http://i.pinimg.com/x.jpg')},
        },
      }),
      isNull,
    );
  });

  test('parses boards with their cover and privacy', () {
    final board = PinterestService.parseBoard({
      'id': '55',
      'name': 'Reactions',
      'pin_count': 12,
      'privacy': 'SECRET',
      'media': {'image_cover_url': 'https://i.pinimg.com/cover.jpg'},
    })!;
    expect(board.name, 'Reactions');
    expect(board.pinCount, 12);
    expect(board.secret, isTrue);
    expect(board.coverUrl, 'https://i.pinimg.com/cover.jpg');
  });

  test('feeds load pages on demand and merge concurrent requests', () async {
    final requested = <String?>[];
    final feed = PinterestFeed<int>((bookmark) async {
      requested.add(bookmark);
      await Future<void>.delayed(Duration.zero);
      return bookmark == null
          ? const PinterestPage([1, 2], 'next')
          : const PinterestPage([3], null);
    });
    expect(feed.hasMore, isTrue);
    await Future.wait([feed.ensureLoaded(), feed.loadMore()]);
    expect(requested, [null]);
    expect(feed.items, [1, 2]);
    expect(feed.complete, isFalse);

    await feed.loadMore();
    expect(requested, [null, 'next']);
    expect(feed.items, [1, 2, 3]);
    expect(feed.complete, isTrue);

    await feed.loadMore();
    expect(requested, hasLength(2));

    feed.reset();
    expect(feed.items, isEmpty);
    await feed.ensureLoaded();
    expect(requested, [null, 'next', null]);
  });

  test('a reset drops a page that was still loading', () async {
    final gate = Completer<void>();
    final feed = PinterestFeed<int>((bookmark) async {
      await gate.future;
      return const PinterestPage([1], null);
    });
    final load = feed.loadMore();
    feed.reset();
    gate.complete();
    await load;
    expect(feed.items, isEmpty);
    expect(feed.loading, isFalse);
  });

  test('feeds skip pages with no image pins', () async {
    final pages = {
      null: const PinterestPage<int>([], 'b'),
      'b': const PinterestPage<int>([], 'c'),
      'c': const PinterestPage([7], null),
    };
    final feed = PinterestFeed<int>((bookmark) async => pages[bookmark]!);
    final before = feed.revision;
    await feed.ensureLoaded();
    expect(feed.items, [7]);
    expect(feed.complete, isTrue);
    expect(feed.revision, greaterThan(before));
  });

  test('secrets are encrypted at rest on Windows', () {
    const secret = '{"accessToken":"a"}';
    final stored = protectSecret(secret);
    if (Platform.isWindows) {
      expect(stored, isNot(contains('accessToken')));
      expect(stored, startsWith('dpapi:'));
    }
    expect(unprotectSecret(stored), secret);
    expect(unprotectSecret(secret), secret);
  });
}
