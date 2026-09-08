import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../i18n/i18n.dart';
import 'package:ffi/ffi.dart';

/// `DATA_BLOB`: a length and a pointer, which is all DPAPI takes.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

/// Encrypts secrets so they can sit in a plain config file.
///
/// Passwords are the one thing a connection manager must not write out in the
/// clear, and a config file is world-readable to anything running as the user.
/// DPAPI ties the ciphertext to the Windows account: another account on the
/// same machine, or the same file copied elsewhere, cannot decrypt it.
///
/// Where no such facility is wired up the answer is not to obfuscate and hope
/// — [isSupported] returns false and the caller declines to store the password
/// at all.
class SecretStore {
  const SecretStore._();

  /// Marks a value as ciphertext, so a hand-edited plaintext password in the
  /// file is still recognised and can be re-protected on the next save.
  static const String prefix = 'dpapi:';

  /// Marks a value kept in the macOS keychain. What follows is not the secret
  /// but the account name it is filed under — the secret never touches the
  /// config file at all, which is a stronger position than ciphertext in it.
  static const String keychainPrefix = 'keychain:';

  /// The keychain service every secret of ours is filed under.
  static const String _service = 'io.github.xsm909.xverb';

  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  /// The line written at the top of a connections file, so what it says about
  /// the passwords in it is true on the machine that wrote it.
  static String get fileNote => switch (Platform.operatingSystem) {
        'windows' => 'Passwords are encrypted for this Windows account and '
            'cannot be moved to another machine or user.',
        'macos' => 'Passwords are not in this file: each one is a reference to '
            'an item in your login keychain.',
        _ => 'Passwords are not saved on this platform.',
      };

  /// A sentence for the UI explaining what protection is available here.
  static String get explanation => switch (Platform.operatingSystem) {
        'windows' => tr('Encrypted with your Windows account. Another account, '
            'or this file copied to another machine, cannot read it.'),
        'macos' => tr('Kept in your login keychain, not in the file. Another '
            'account, or this file copied to another machine, finds nothing.'),
        _ => tr('This platform has no key store wired up yet, so passwords are '
            'not saved. You will be asked when connecting.'),
      };

  /// Returns the protected form of [secret], or null when it cannot be done.
  static String? protect(String secret) {
    if (!isSupported || secret.isEmpty) return null;
    if (Platform.isMacOS) return _keychainStore(secret);
    final bytes = utf8.encode(secret);
    final result = _crypt('CryptProtectData', bytes);
    return result == null ? null : prefix + base64Encode(result);
  }

  /// Recovers a secret written by [protect]. Null when it is not ours to read
  /// — a different account, or a corrupted value.
  static String? unprotect(String stored) {
    if (stored.startsWith(keychainPrefix)) {
      return Platform.isMacOS
          ? _keychainRead(stored.substring(keychainPrefix.length))
          : null;
    }
    if (!stored.startsWith(prefix)) return null;
    if (!Platform.isWindows) return null;

    Uint8List cipher;
    try {
      cipher = base64Decode(stored.substring(prefix.length));
    } on FormatException {
      return null;
    }

    final plain = _crypt('CryptUnprotectData', cipher);
    if (plain == null) return null;
    try {
      return utf8.decode(plain);
    } on FormatException {
      return null;
    }
  }

  /// Whether a stored value is one of ours rather than a plain password.
  ///
  /// Every prefix [protect] can produce has to be listed here. Missing one is
  /// not a cosmetic slip: the caller then treats the *reference* as the
  /// password and sends it to the server, which fails as an ordinary wrong
  /// password and points nowhere near the cause.
  static bool looksProtected(String value) =>
      value.startsWith(prefix) || value.startsWith(keychainPrefix);

  /// Removes a stored secret, for when the connection holding it is deleted.
  ///
  /// Only the keychain needs this: DPAPI ciphertext lives in the file and goes
  /// when the file does, while a keychain item would otherwise outlive
  /// everything that referred to it.
  static void forget(String stored) {
    if (!Platform.isMacOS || !stored.startsWith(keychainPrefix)) return;
    Process.runSync('/usr/bin/security', [
      'delete-generic-password',
      '-a', stored.substring(keychainPrefix.length),
      '-s', _service,
    ]);
  }

  // --- macOS ---------------------------------------------------------------
  //
  // `security` rather than the Security framework through FFI. The command is
  // part of the system, has been for twenty years, and keeps this to a few
  // lines that can be read and checked — against an FFI binding to a C API
  // whose mistakes are segfaults.

  static String? _keychainStore(String secret) {
    // A fresh account name each time, so re-saving never has to find and
    // update the old item, and two connections never collide.
    final account = 'connection-'
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final result = Process.runSync('/usr/bin/security', [
      'add-generic-password',
      '-a', account,
      '-s', _service,
      '-w', secret,
      '-U', // update in place if it somehow exists already
    ]);
    if (result.exitCode != 0) return null;
    return keychainPrefix + account;
  }

  static String? _keychainRead(String account) {
    final result = Process.runSync('/usr/bin/security', [
      'find-generic-password',
      '-a', account,
      '-s', _service,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    final secret = (result.stdout as String).trimRight();
    return secret.isEmpty ? null : secret;
  }

  /// Both DPAPI calls take and return a `DATA_BLOB` and differ only in name.
  static Uint8List? _crypt(String function, List<int> input) {
    try {
      final crypt32 = DynamicLibrary.open('crypt32.dll');
      final call = crypt32.lookupFunction<
          Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
              Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>),
          int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
              Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>)>(function);

      final inBlob = calloc<_DataBlob>();
      final outBlob = calloc<_DataBlob>();
      final buffer = calloc<Uint8>(input.length);
      try {
        buffer.asTypedList(input.length).setAll(0, input);
        inBlob.ref
          ..cbData = input.length
          ..pbData = buffer;

        final ok = call(
          inBlob,
          nullptr,
          nullptr,
          nullptr,
          nullptr,
          0,
          outBlob,
        );
        if (ok == 0 || outBlob.ref.pbData == nullptr) return null;

        // Copy before freeing: the buffer belongs to the OS until LocalFree.
        final output = Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
        );
        _localFree(outBlob.ref.pbData);
        return output;
      } finally {
        calloc.free(buffer);
        calloc.free(inBlob);
        calloc.free(outBlob);
      }
    } on Object {
      return null;
    }
  }

  static void _localFree(Pointer<Uint8> pointer) {
    try {
      DynamicLibrary.open('kernel32.dll').lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Uint8>)>('LocalFree')(pointer);
    } on Object {
      // Leaking a few bytes is better than crashing on shutdown.
    }
  }
}
