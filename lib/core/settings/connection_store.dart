import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../plugins/plugin_manifest.dart';
import '../security/secret_store.dart';
import '../vfs/vfs_path.dart';
import 'ini_file.dart';

/// Whatever was typed into a "host" field, taken apart.
///
/// Accepts a bare name, `host:port`, and a full URL with credentials and a
/// path — which is what people actually paste, since it is the form they were
/// given by a web page or a colleague.
class HostAddress {
  const HostAddress({
    required this.host,
    this.port,
    this.user,
    this.password,
    this.path = '',
  });

  final String host;
  final int? port;
  final String? user;
  final String? password;
  final String path;

  static HostAddress parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const HostAddress(host: '');

    String? user;
    String? password;
    var path = '';

    // A scheme is redundant here — the connection already knows its own — but
    // it must not end up inside the host name.
    final scheme = text.indexOf('://');
    if (scheme >= 0) text = text.substring(scheme + 3);

    final at = text.lastIndexOf('@');
    if (at > 0) {
      final credentials = text.substring(0, at);
      text = text.substring(at + 1);
      final colon = credentials.indexOf(':');
      if (colon >= 0) {
        user = Uri.decodeComponent(credentials.substring(0, colon));
        password = Uri.decodeComponent(credentials.substring(colon + 1));
      } else {
        user = Uri.decodeComponent(credentials);
      }
    }

    final slash = text.indexOf('/');
    if (slash >= 0) {
      path = text.substring(slash);
      text = text.substring(0, slash);
    }

    // A port is a colon that is not part of the address. In an IPv6 literal
    // the colons live inside brackets, so only one after the closing bracket
    // counts; a bare name may have exactly one.
    int? port;
    final bracket = text.lastIndexOf(']');
    final colon = text.lastIndexOf(':');
    final isPortSeparator = bracket >= 0
        ? colon > bracket
        : colon > 0 && !text.substring(0, colon).contains(':');

    if (isPortSeparator) {
      final parsed = int.tryParse(text.substring(colon + 1));
      if (parsed != null) {
        port = parsed;
        text = text.substring(0, colon);
      }
    }

    return HostAddress(
      host: text,
      port: port,
      user: user,
      password: password,
      // A lone "/" is the root and adds nothing.
      path: path == '/' ? '' : path,
    );
  }
}

/// One saved connection: the answers to a [ConnectionSpec]'s form.
class SavedConnection {
  SavedConnection({
    required this.name,
    required this.specId,
    required this.scheme,
    required this.storeFile,
    Map<String, String>? values,
  }) : values = values ?? <String, String>{};

  /// Section name in the INI, and what the user sees in the list.
  final String name;

  final String specId;
  final String scheme;
  final String storeFile;

  /// Raw field values. The password, if present, is stored protected.
  final Map<String, String> values;

  String? operator [](String key) => values[key];

  bool get isTrue => false;

  bool flag(String key, {bool fallback = false}) {
    final value = values[key];
    if (value == null) return fallback;
    return value == 'true' || value == '1' || value == 'yes';
  }

  /// True when a password was saved with this connection.
  bool get hasStoredPassword {
    final stored = values[ConnectionSpec.passwordKey];
    return stored != null && stored.isNotEmpty;
  }

  /// The password in the clear, or null when none is stored or it cannot be
  /// decrypted — a file copied from another machine, for instance.
  String? revealPassword() {
    final stored = values[ConnectionSpec.passwordKey];
    if (stored == null || stored.isEmpty) return null;
    return SecretStore.looksProtected(stored)
        ? SecretStore.unprotect(stored)
        : stored;
  }

  /// True when a password was saved and can no longer be read back.
  ///
  /// Worth telling apart from "no password was saved": both leave the field
  /// empty, but only this one means something was lost — a keychain item
  /// removed, or a file carried to another account. Connecting with a silently
  /// empty password just fails at the far end, which points at the server
  /// rather than at the thing that actually went missing.
  bool get passwordIsLost {
    final stored = values[ConnectionSpec.passwordKey];
    if (stored == null || stored.isEmpty) return false;
    if (!SecretStore.looksProtected(stored)) return false;
    return SecretStore.unprotect(stored) == null;
  }

  /// Builds the URL the panel navigates to.
  ///
  /// [password] overrides whatever is stored, which is how a connection that
  /// deliberately keeps no password gets one for the session.
  VfsPath toPath({String? password}) {
    // People paste whole URLs into a field labelled "host", and they are not
    // wrong to: it is the thing they have in their hand. Take it apart rather
    // than building a URI with "ftp://host/" as the host name.
    final address = HostAddress.parse(values[ConnectionSpec.hostKey] ?? '');
    final host = address.host;
    final port = int.tryParse(values[ConnectionSpec.portKey] ?? '') ??
        address.port;
    final user = (values[ConnectionSpec.userKey]?.trim().isNotEmpty ?? false)
        ? values[ConnectionSpec.userKey]!.trim()
        : (address.user ?? '');
    final secret = password ?? revealPassword() ?? address.password ?? '';

    var userInfo = '';
    if (user.isNotEmpty) {
      userInfo = Uri.encodeComponent(user);
      if (secret.isNotEmpty) userInfo += ':${Uri.encodeComponent(secret)}';
    }

    var path = values[ConnectionSpec.pathKey]?.trim() ?? '';
    if (path.isEmpty) path = address.path;
    if (path.isNotEmpty && !path.startsWith('/')) path = '/$path';

    // Everything the host does not understand goes to the plugin as a query
    // parameter, so a transport can carry its own options.
    final query = <String, String>{};
    for (final entry in values.entries) {
      if (ConnectionSpec.structuralKeys.contains(entry.key)) continue;
      if (entry.value.isEmpty) continue;
      query[entry.key] = entry.value;
    }

    return VfsPath(Uri(
      scheme: scheme,
      userInfo: userInfo.isEmpty ? null : userInfo,
      host: host.isEmpty ? null : host,
      port: port,
      path: path.isEmpty ? '/' : path,
      queryParameters: query.isEmpty ? null : query,
    ));
  }

  /// The connection as shown in lists: never with the password in it.
  String get summary {
    final user = values[ConnectionSpec.userKey];
    final host = values[ConnectionSpec.hostKey] ?? '';
    final port = values[ConnectionSpec.portKey];
    final where = port == null || port.isEmpty ? host : '$host:$port';
    return user == null || user.isEmpty ? where : '$user@$where';
  }
}

/// Reads and writes the saved connections.
///
/// One INI file per transport, in the app's `connections` directory, so they
/// can be opened in a text editor — which is also why passwords are never
/// written in the clear. See [SecretStore].
class ConnectionStore extends ChangeNotifier {
  ConnectionStore();

  final Map<String, List<SavedConnection>> _byFile = {};

  Directory? _directory;

  String? get directoryPath => _directory?.path;

  /// Every connection loaded so far, in file then file order.
  List<SavedConnection> get all =>
      [for (final list in _byFile.values) ...list];

  List<SavedConnection> forSpec(ConnectionSpec spec) =>
      (_byFile[spec.storeFile] ?? const [])
          .where((c) => c.specId == spec.id)
          .toList();

  Future<void> initialize() async {
    final support = await getApplicationSupportDirectory();
    _directory = Directory(p.join(support.path, 'connections'));
    await _directory!.create(recursive: true);

    await for (final entry in _directory!.list()) {
      if (entry is File && entry.path.toLowerCase().endsWith('.ini')) {
        await _load(p.basename(entry.path));
      }
    }
    notifyListeners();
  }

  Future<void> _load(String storeFile) async {
    final file = File(p.join(_directory!.path, storeFile));
    if (!await file.exists()) {
      _byFile[storeFile] = [];
      return;
    }

    final ini = IniFile.parse(await file.readAsString());
    _byFile[storeFile] = [
      for (final section in ini.sections.entries)
        SavedConnection(
          name: section.key,
          specId: section.value['spec'] ?? '',
          scheme: section.value['scheme'] ?? '',
          storeFile: storeFile,
          values: Map.of(section.value)
            ..remove('spec')
            ..remove('scheme'),
        ),
    ];
  }

  /// Adds or replaces a connection, keyed by its name.
  ///
  /// [password] is protected before it touches the disk; when it cannot be
  /// protected nothing is written, and the user is asked at connect time.
  Future<void> save(
    ConnectionSpec spec,
    SavedConnection connection, {
    String? password,
    bool storePassword = false,
  }) async {
    final values = Map.of(connection.values)
      ..remove(ConnectionSpec.passwordKey);

    if (storePassword && password != null && password.isNotEmpty) {
      final protected = SecretStore.protect(password);
      if (protected != null) values[ConnectionSpec.passwordKey] = protected;
    }

    final saved = SavedConnection(
      name: IniFile.sanitiseSectionName(connection.name),
      specId: spec.id,
      scheme: spec.scheme,
      storeFile: spec.storeFile,
      values: values,
    );

    final list = _byFile.putIfAbsent(spec.storeFile, () => []);
    final existing = list.indexWhere((c) => c.name == saved.name);
    if (existing >= 0) {
      list[existing] = saved;
    } else {
      list.add(saved);
    }

    await _write(spec.storeFile);
    notifyListeners();
  }

  Future<void> delete(SavedConnection connection) async {
    final list = _byFile[connection.storeFile];
    if (list == null) return;
    list.removeWhere((c) => c.name == connection.name);
    await _write(connection.storeFile);
    notifyListeners();
  }

  Future<void> _write(String storeFile) async {
    final directory = _directory;
    if (directory == null) return;

    final ini = IniFile();
    for (final connection in _byFile[storeFile] ?? const <SavedConnection>[]) {
      ini.sections[connection.name] = {
        'spec': connection.specId,
        'scheme': connection.scheme,
        for (final entry in connection.values.entries)
          entry.key: IniFile.sanitiseValue(entry.value),
      };
    }

    final file = File(p.join(directory.path, storeFile));
    await file.writeAsString(
      '; xverb connections. Safe to edit by hand.\n'
      '; ${SecretStore.fileNote}\n\n'
      '${ini.encode()}',
    );
  }
}
