import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'library_store.dart';
import 'secret_storage.dart';

class PinterestBoard {
  const PinterestBoard({
    required this.id,
    required this.name,
    required this.pinCount,
    this.coverUrl,
    this.secret = false,
  });

  final String id;
  final String name;
  final int pinCount;
  final String? coverUrl;
  final bool secret;
}

class PinterestPin {
  const PinterestPin({
    required this.id,
    required this.title,
    required this.mediaUrl,
    required this.previewUrl,
  });

  final String id;
  final String title;
  final String mediaUrl;
  final String previewUrl;

  bool get isGif => Uri.parse(mediaUrl).path.toLowerCase().endsWith('.gif');
  String get pageUrl => 'https://www.pinterest.com/pin/$id/';

  /// The library keeps the pin as a link back to Pinterest, never a copy.
  MediaLink toLink({bool favorite = false}) => MediaLink(
    name: title,
    kind: isGif ? 'gif' : 'sticker',
    mediaUrl: mediaUrl,
    previewUrl: previewUrl,
    sourceType: 'pinterest',
    sourceId: id,
    sourcePage: pageUrl,
    favorite: favorite,
  );
}

class PinterestPage<T> {
  const PinterestPage(this.items, this.bookmark);
  final List<T> items;

  /// Pass back to fetch the next page; null on the last page.
  final String? bookmark;
}

/// A paginated listing kept in memory for this session, so returning to it
/// does not refetch. Pages load on demand and concurrent requests for the
/// next page are merged. Nothing is written to disk.
class PinterestFeed<T> extends ChangeNotifier {
  PinterestFeed(this._fetch);

  final Future<PinterestPage<T>> Function(String? bookmark) _fetch;
  final items = <T>[];
  String? _bookmark;
  bool _started = false;
  bool loading = false;
  Object? error;
  Future<void>? _pending;
  int _generation = 0;

  /// Changes whenever [items] does, so views can cache derived lists.
  int revision = 0;

  /// Pages that yield nothing after filtering (for example only video pins)
  /// are skipped, up to this many in a row, so a listing never sits empty
  /// while more pages exist.
  static const _maxEmptyPages = 10;

  /// Whether every page has been loaded.
  bool get complete => _started && _bookmark == null && error == null;
  bool get hasMore => !_started || _bookmark != null;

  /// Loads the first page if nothing is loaded yet.
  Future<void> ensureLoaded() => _started ? Future.value() : loadMore();

  Future<void> loadMore() {
    final pending = _pending;
    if (pending != null) return pending;
    if (!hasMore) return Future.value();
    final load = _load();
    _pending = load;
    return load.whenComplete(() {
      if (identical(_pending, load)) _pending = null;
    });
  }

  Future<void> _load() async {
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      for (var empty = 0; ; empty++) {
        final page = await _fetch(_started ? _bookmark : null);
        if (generation != _generation) return;
        items.addAll(page.items);
        _bookmark = page.bookmark;
        _started = true;
        revision++;
        if (page.items.isNotEmpty ||
            _bookmark == null ||
            empty + 1 >= _maxEmptyPages) {
          break;
        }
      }
    } catch (e) {
      if (generation == _generation) error = e;
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void reset() {
    _generation++;
    _pending = null;
    items.clear();
    _bookmark = null;
    _started = false;
    loading = false;
    error = null;
    revision++;
    notifyListeners();
  }
}

class PinterestException implements Exception {
  const PinterestException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The code or refresh token was rejected; a new sign-in is needed.
class PinterestSessionExpired extends PinterestException {
  const PinterestSessionExpired(super.message);
}

class _Session {
  _Session({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.username,
  });

  String accessToken;
  String refreshToken;
  DateTime expiresAt;
  String? username;

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'username': username,
  };

  static _Session fromJson(Map<String, dynamic> data) => _Session(
    accessToken: data['accessToken'] as String,
    refreshToken: data['refreshToken'] as String,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(data['expiresAt'] as int),
    username: data['username'] as String?,
  );
}

/// Reads the signed-in person's Pinterest boards and pins.
///
/// Sign-in goes through the `pinterest-oauth` Supabase Edge Function, which
/// holds the app secret. Tokens stay on this device. Pinterest content is
/// never stored: boards and pins are fetched live, and saved pins are links.
class PinterestService extends ChangeNotifier {
  PinterestService({
    required this.functionUrl,
    this.publishableKey = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Hidden until the Edge Function is deployed and the app is approved.
  static const enabled = bool.fromEnvironment('PINTEREST_ENABLED');
  static const _prefsKey = 'pinterest_session';

  final String functionUrl;
  final String publishableKey;
  final http.Client _client;
  _Session? _session;
  Future<void>? _refreshing;
  bool _loaded = false;

  bool get configured => enabled && functionUrl.isNotEmpty;
  bool get connected => _session != null;
  String? get username => _session?.username;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored == null) return;
    final raw = unprotectSecret(stored);
    try {
      if (raw == null) throw const FormatException('Unreadable session');
      _session = _Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Sessions saved before encryption are rewritten encrypted.
      if (raw == stored) await _persist();
    } catch (_) {
      await prefs.remove(_prefsKey);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final session = _session;
    if (session == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(
        _prefsKey,
        protectSecret(jsonEncode(session.toJson())),
      );
    }
    notifyListeners();
  }

  /// Opens Pinterest's consent page in the browser and waits for the app to
  /// receive the authorization code.
  Future<void> connect() async {
    if (!configured) {
      throw const PinterestException(
        'Pinterest is not available in this build',
      );
    }
    final random = Random.secure();
    final nonce = base64Url
        .encode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final String code;
    if (Platform.isWindows) {
      code = await _connectWithLoopback(nonce);
    } else if (Platform.isAndroid) {
      code = await _connectWithDeepLink(nonce);
    } else {
      throw const PinterestException('Pinterest sign-in is not supported here');
    }
    final tokens = await _token({
      'grant_type': 'authorization_code',
      'code': code,
    });
    _session = _sessionFrom(tokens);
    try {
      final account = await _get('/user_account');
      _session!.username = account['username'] as String?;
    } catch (_) {
      // The account name is only shown as a label.
    }
    await _persist();
  }

  Uri _startUri(String state) =>
      Uri.parse(functionUrl)
          .replace(queryParameters: {'start': '1', 'state': state});

  Future<void> _openBrowser(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const PinterestException('Could not open the browser');
    }
  }

  /// Windows has no app link, so Pinterest's redirect is forwarded to a
  /// one-time listener on 127.0.0.1.
  Future<String> _connectWithLoopback(String nonce) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = '$nonce.w${server.port}';
    try {
      await _openBrowser(_startUri(state));
      await for (final request in server.timeout(const Duration(minutes: 5))) {
        final params = request.uri.queryParameters;
        if (request.uri.path != '/pinterest-callback' ||
            params['state'] != state) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        final code = params['pinterest_code'];
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            '<!doctype html><meta charset="utf-8"><title>Memlib</title>'
            '<body style="font:16px system-ui;background:#0E0C13;color:#F3F1F7;'
            'display:grid;place-items:center;height:90vh">'
            '<p>${code == null ? 'Pinterest was not connected.' : 'Pinterest is connected.'}'
            ' You can close this tab and return to Memlib.</p>',
          );
        await request.response.close();
        if (code == null) {
          throw PinterestException(
            'Pinterest sign-in was cancelled (${params['pinterest_error']})',
          );
        }
        return code;
      }
      throw const PinterestException('Pinterest sign-in did not finish');
    } on TimeoutException {
      throw const PinterestException('Pinterest sign-in timed out');
    } finally {
      await server.close(force: true);
    }
  }

  Future<String> _connectWithDeepLink(String nonce) async {
    final state = '$nonce.android';
    final callback = AppLinks().uriLinkStream
        .firstWhere(
          (uri) =>
              uri.host == 'pinterest-callback' &&
              uri.queryParameters['state'] == state,
        )
        .timeout(const Duration(minutes: 5));
    await _openBrowser(_startUri(state));
    try {
      final uri = await callback;
      final code = uri.queryParameters['pinterest_code'];
      if (code == null) {
        throw PinterestException(
          'Pinterest sign-in was cancelled '
          '(${uri.queryParameters['pinterest_error']})',
        );
      }
      return code;
    } on TimeoutException {
      throw const PinterestException('Pinterest sign-in timed out');
    }
  }

  Future<void> disconnect() async {
    _session = null;
    clearFeeds();
    await _persist();
  }

  Future<Map<String, dynamic>> _token(Map<String, String> body) async {
    final response = await _client.post(
      Uri.parse(functionUrl),
      headers: {
        'content-type': 'application/json',
        if (publishableKey.isNotEmpty) 'apikey': publishableKey,
      },
      body: jsonEncode(body),
    );
    final data = jsonDecode(response.body);
    if (response.statusCode == 400) {
      throw PinterestSessionExpired(
        'Pinterest sign-in expired: ${data is Map ? data['error'] : ''}',
      );
    }
    if (response.statusCode != 200 || data is! Map<String, dynamic>) {
      throw PinterestException(
        'Pinterest sign-in failed (${response.statusCode})',
      );
    }
    return data;
  }

  _Session _sessionFrom(Map<String, dynamic> tokens, {String? username}) {
    final access = tokens['access_token'];
    final refresh = tokens['refresh_token'] ?? _session?.refreshToken;
    if (access is! String || refresh is! String) {
      throw const PinterestException('Pinterest did not return a session');
    }
    return _Session(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(
        Duration(seconds: (tokens['expires_in'] as num?)?.toInt() ?? 3600),
      ),
      username: username,
    );
  }

  /// Concurrent requests share one refresh.
  Future<void> _refresh() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final refresh = _refreshSession();
    _refreshing = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_refreshing, refresh)) _refreshing = null;
    }
  }

  Future<void> _refreshSession() async {
    final session = _session;
    if (session == null) {
      throw const PinterestException('Connect Pinterest first');
    }
    try {
      final tokens = await _token({
        'grant_type': 'refresh_token',
        'refresh_token': session.refreshToken,
      });
      _session = _sessionFrom(tokens, username: session.username);
      await _persist();
    } on PinterestSessionExpired {
      // An expired refresh token needs a new sign-in.
      await disconnect();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    if (_session == null) {
      throw const PinterestException('Connect Pinterest first');
    }
    if (_session!.expiresAt.difference(DateTime.now()) <
        const Duration(days: 1)) {
      await _refresh();
    }
    final uri = Uri.https('api.pinterest.com', '/v5$path', query);
    // A concurrent disconnect can clear the session between awaits.
    Future<http.Response> send() {
      final session = _session;
      if (session == null) {
        throw const PinterestException('Connect Pinterest first');
      }
      return _client.get(
        uri,
        headers: {'authorization': 'Bearer ${session.accessToken}'},
      );
    }

    var response = await send();
    if (response.statusCode == 401) {
      await _refresh();
      response = await send();
    }
    if (response.statusCode == 429) {
      // Wait out a short rate-limit window once before giving up.
      final wait = int.tryParse(response.headers['retry-after'] ?? '') ?? 2;
      if (wait <= 10) {
        await Future<void>.delayed(Duration(seconds: wait));
        response = await send();
      }
    }
    if (response.statusCode == 429) {
      throw const PinterestException(
        'Pinterest rate limit reached. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw PinterestException(
        'Pinterest request failed (${response.statusCode})',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<PinterestPage<PinterestBoard>> boards({String? bookmark}) async {
    final data = await _get('/boards', {
      'page_size': '100',
      'bookmark': ?bookmark,
    });
    return PinterestPage([
      for (final raw in data['items'] as List<dynamic>? ?? [])
        if (raw is Map<String, dynamic>) ?parseBoard(raw),
    ], data['bookmark'] as String?);
  }

  /// One page of a board's pins. Browsing uses small pages so the first
  /// tiles appear quickly; importing uses Pinterest's maximum of 250.
  Future<PinterestPage<PinterestPin>> pins(
    String boardId, {
    String? bookmark,
    int pageSize = 50,
  }) async {
    final data = await _get('/boards/${Uri.encodeComponent(boardId)}/pins', {
      'page_size': '$pageSize',
      'bookmark': ?bookmark,
    });
    return PinterestPage([
      for (final raw in data['items'] as List<dynamic>? ?? [])
        if (raw is Map<String, dynamic>) ?parsePin(raw),
    ], data['bookmark'] as String?);
  }

  /// Every pin on a board, in pages of 250. A board already browsed to the
  /// end this session is not fetched again.
  Future<List<PinterestPin>> allPins(String boardId) async {
    final browsed = _pinFeeds[boardId];
    if (browsed != null && browsed.complete) return List.of(browsed.items);
    final pins = <PinterestPin>[];
    String? bookmark;
    do {
      final page = await this.pins(boardId, bookmark: bookmark, pageSize: 250);
      pins.addAll(page.items);
      bookmark = page.bookmark;
    } while (bookmark != null && pins.length < 10000);
    return pins;
  }

  /// The person's boards, loaded a page at a time and kept for the session.
  late final boardFeed = PinterestFeed<PinterestBoard>(
    (bookmark) => boards(bookmark: bookmark),
  );
  final _pinFeeds = <String, PinterestFeed<PinterestPin>>{};

  /// A board's pins, loaded a page at a time and kept for the session.
  PinterestFeed<PinterestPin> pinFeed(String boardId) => _pinFeeds.putIfAbsent(
    boardId,
    () => PinterestFeed((bookmark) => pins(boardId, bookmark: bookmark)),
  );

  final _importing = <String>{};

  /// Whether a board's pins are being added to the library.
  bool isImporting(String boardId) => _importing.contains(boardId);

  /// Marks a board import as running; false if one already is.
  bool startImport(String boardId) {
    if (!_importing.add(boardId)) return false;
    notifyListeners();
    return true;
  }

  void endImport(String boardId) {
    if (_importing.remove(boardId)) notifyListeners();
  }

  /// Forgets every listing, so the next view fetches fresh data.
  void clearFeeds() {
    boardFeed.reset();
    // Reset rather than dispose: a view may still be listening.
    for (final feed in _pinFeeds.values) {
      feed.reset();
    }
    _pinFeeds.clear();
  }

  static bool _https(String? url) =>
      url != null && Uri.tryParse(url)?.scheme == 'https';

  @visibleForTesting
  static PinterestBoard? parseBoard(Map<String, dynamic> raw) {
    final id = raw['id']?.toString();
    final name = raw['name']?.toString();
    if (id == null || id.isEmpty || name == null) return null;
    final cover = (raw['media'] as Map<String, dynamic>?)?['image_cover_url'];
    return PinterestBoard(
      id: id,
      name: name,
      pinCount: (raw['pin_count'] as num?)?.toInt() ?? 0,
      coverUrl: cover is String && _https(cover) ? cover : null,
      secret: raw['privacy'] == 'SECRET',
    );
  }

  /// Image pins only: video pins expose just a cover image.
  @visibleForTesting
  static PinterestPin? parsePin(Map<String, dynamic> raw) {
    final id = raw['id']?.toString();
    final media = raw['media'] as Map<String, dynamic>?;
    if (id == null || id.isEmpty || media == null) return null;
    if (media['media_type'] == 'video') return null;
    var images = media['images'] as Map<String, dynamic>?;
    final carousel = media['items'];
    if (images == null && carousel is List && carousel.isNotEmpty) {
      images =
          (carousel.first as Map<String, dynamic>?)?['images']
              as Map<String, dynamic>?;
    }
    String? image(String size) =>
        (images?[size] as Map<String, dynamic>?)?['url'] as String?;
    final full = image('originals') ?? image('1200x') ?? image('600x');
    final preview = image('600x') ?? image('400x300') ?? full;
    if (!_https(full) || !_https(preview)) return null;
    String? text(String key) {
      final value = raw[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    var title = text('title') ?? text('description') ?? 'Pinterest pin';
    if (title.length > 120) title = '${title.substring(0, 117)}…';
    return PinterestPin(
      id: id,
      title: title,
      mediaUrl: full!,
      previewUrl: preview!,
    );
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
