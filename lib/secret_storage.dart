import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _prefix = 'dpapi:';
const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

/// Encrypts a secret for the current Windows user (DPAPI) before it is
/// written to SharedPreferences, which on Windows is a plain JSON file.
/// Android's preferences are already private to the app, so other platforms
/// keep the value as is.
String protectSecret(String value) {
  if (!Platform.isWindows) return value;
  final sealed = _dpapi(utf8.encode(value), protect: true);
  if (sealed == null) throw StateError('Windows could not encrypt the secret');
  return '$_prefix${base64.encode(sealed)}';
}

/// Reverses [protectSecret]. Values saved before encryption are returned as
/// is; null means the value cannot be decrypted (another user or machine).
String? unprotectSecret(String stored) {
  if (!stored.startsWith(_prefix)) return stored;
  if (!Platform.isWindows) return null;
  try {
    final opened = _dpapi(
      base64.decode(stored.substring(_prefix.length)),
      protect: false,
    );
    return opened == null ? null : utf8.decode(opened);
  } on FormatException {
    return null;
  }
}

Uint8List? _dpapi(List<int> input, {required bool protect}) {
  final data = calloc<Uint8>(input.isEmpty ? 1 : input.length);
  final inBlob = calloc<CRYPT_INTEGER_BLOB>();
  final outBlob = calloc<CRYPT_INTEGER_BLOB>();
  try {
    data.asTypedList(input.length).setAll(0, input);
    inBlob.ref
      ..cbData = input.length
      ..pbData = data;
    final ok = protect
        ? CryptProtectData(
            inBlob,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            _uiForbidden,
            outBlob,
          )
        : CryptUnprotectData(
            inBlob,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            _uiForbidden,
            outBlob,
          );
    if (ok == 0) return null;
    final result = Uint8List.fromList(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
    LocalFree(outBlob.ref.pbData);
    return result;
  } finally {
    calloc.free(data);
    calloc.free(inBlob);
    calloc.free(outBlob);
  }
}
