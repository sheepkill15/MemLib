import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_sync.dart';
import 'library_store.dart';

const authCallbackUrl = 'com.sheepkill15.memlib://auth-callback';

class CloudController extends ChangeNotifier {
  CloudController(this.store, this.client, {RemoteLibrary? remote})
    : remote =
          remote ?? (client == null ? null : SupabaseRemoteLibrary(client));

  final LibraryStore store;
  final SupabaseClient? client;
  final RemoteLibrary? remote;
  User? user;
  bool syncing = false;
  bool guestLibraryAvailable = false;
  String? syncError;
  SyncConflict? conflict;
  DateTime? lastSyncedAt;

  StreamSubscription<AuthState>? _authSubscription;
  Timer? _periodic;
  Timer? _debounce;
  Future<void> _tail = Future<void>.value();
  bool _suppressStoreChanges = false;
  bool _syncQueued = false;
  bool _disposed = false;

  bool get configured => client != null;
  bool get signedIn => user != null;
  String? get email => user?.email;

  Future<void> start() async {
    if (client == null) return;
    guestLibraryAvailable = await store.hasGuestLibrary();
    _authSubscription = client!.auth.onAuthStateChange.listen((state) {
      unawaited(_enqueue(() => _switchUser(state.session?.user)));
    });
    await _enqueue(() => _switchUser(client!.auth.currentUser));
    store.addListener(_onStoreChanged);
    _periodic = Timer.periodic(
      const Duration(seconds: 45),
      (_) => scheduleSync(),
    );
  }

  Future<void> _switchUser(User? next) async {
    if (_disposed || user?.id == next?.id) return;
    _debounce?.cancel();
    _suppressStoreChanges = true;
    try {
      await store.openAccount(next?.id);
      user = next;
      syncError = null;
      conflict = null;
      lastSyncedAt = null;
      _notify();
    } finally {
      _suppressStoreChanges = false;
    }
    if (next != null) scheduleSync(immediate: true);
  }

  Future<void> signIn(String email, String password) async {
    if (client == null) throw StateError('Supabase is not configured');
    final response = await client!.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    await _enqueue(() => _switchUser(response.user));
  }

  Future<bool> signUp(String email, String password) async {
    if (client == null) throw StateError('Supabase is not configured');
    final response = await client!.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: Platform.isWindows || Platform.isAndroid
          ? authCallbackUrl
          : null,
    );
    if (response.session != null) {
      await _enqueue(() => _switchUser(response.user));
    }
    return response.session != null;
  }

  Future<void> signOut() async {
    if (client == null) return;
    await client!.auth.signOut();
    await _enqueue(() => _switchUser(null));
  }

  Future<int> importGuestLibrary() async {
    if (user == null) throw StateError('Sign in before importing');
    final count = await store.importGuestLibrary();
    guestLibraryAvailable = await store.hasGuestLibrary();
    _notify();
    scheduleSync(immediate: true);
    return count;
  }

  void _onStoreChanged() {
    if (!_suppressStoreChanges && user != null) scheduleSync();
  }

  void scheduleSync({bool immediate = false}) {
    if (_disposed || user == null || remote == null) return;
    _debounce?.cancel();
    _debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 900),
      () {
        if (_syncQueued) return;
        _syncQueued = true;
        unawaited(
          _enqueue(() async {
            try {
              await _performSync();
            } finally {
              _syncQueued = false;
            }
          }),
        );
      },
    );
  }

  Future<void> syncNow() async {
    _debounce?.cancel();
    await _enqueue(_performSync);
  }

  Future<void> _performSync() async {
    final activeUser = user;
    if (_disposed ||
        activeUser == null ||
        remote == null ||
        client?.auth.currentUser?.id != activeUser.id) {
      return;
    }
    syncing = true;
    syncError = null;
    conflict = null;
    _notify();
    _suppressStoreChanges = true;
    try {
      await CloudSyncEngine(store, remote!, activeUser.id).sync();
      lastSyncedAt = DateTime.now();
    } catch (e) {
      syncError = e.toString();
      if (e is SyncConflict) conflict = e;
    } finally {
      _suppressStoreChanges = false;
      syncing = false;
      _notify();
    }
    if (syncError == null &&
        (store.dirtyFolders.isNotEmpty ||
            store.dirtyItems.isNotEmpty ||
            store.deletedFolders.isNotEmpty ||
            store.deletedItems.isNotEmpty)) {
      scheduleSync();
    }
  }

  Future<void> resolveConflict({required bool keepDevice}) async {
    final pending = conflict;
    final activeUser = user;
    if (pending == null || activeUser == null || remote == null) return;
    await _enqueue(() async {
      final version = pending.entity == 'folder'
          ? (await remote!.fetchFolders(activeUser.id))
                .where((row) => row.folder.id == pending.id)
                .firstOrNull
                ?.version
          : (await remote!.fetchItems(activeUser.id))
                .where((row) => row.item.id == pending.id)
                .firstOrNull
                ?.version;
      _suppressStoreChanges = true;
      try {
        await store.resolveConflict(
          pending.entity,
          pending.id,
          keepDevice: keepDevice,
          remoteVersion: version,
        );
        conflict = null;
        syncError = null;
        _notify();
      } finally {
        _suppressStoreChanges = false;
      }
      await _performSync();
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.catchError((Object error, StackTrace stack) {
      if (!_disposed) {
        syncError = error.toString();
        _notify();
      }
    });
    return next;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _authSubscription?.cancel();
    store.removeListener(_onStoreChanged);
    super.dispose();
  }
}
