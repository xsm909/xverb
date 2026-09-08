import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Pictures of the people a listing names, kept on the disk.
///
/// **The one place in this application that fetches anything because of what
/// is on screen**, and it is built to be exactly that and nothing more:
///
/// - It goes to **two hosts and no others**, and asks each for one thing: the
///   picture belonging to an address. A plugin cannot point this at a url of
///   its own — it hands over an address and gets a picture of a person or
///   nothing, which is the whole of what it can cause. Both urls are worked
///   out *from the address itself*: no lookup, no key, no account.
/// - It **never blocks a row.** A listing draws initials and carries on; when
///   a picture arrives the rows that wanted it are redrawn. A log that waited
///   on a server to draw a line would be a log that hangs on a repository you
///   walked past.
/// - It asks **once** per address per run, and remembers "there is none" as
///   firmly as it remembers a picture. Somebody with no Gravatar must not cost
///   a request per repaint.
/// - What it has fetched stays on the disk, so the second visit to a
///   repository costs nothing at all.
class AvatarStore {
  AvatarStore._();

  static final AvatarStore instance = AvatarStore._();

  /// Where the pictures live. Null until it is worked out, and settable so a
  /// test can point it somewhere it is allowed to write.
  Directory? home;

  /// What is known: a file that exists, or null for "asked, and there is
  /// none". An address absent from this map has not been asked about.
  final Map<String, File?> _known = {};

  /// Addresses being asked about now, so a listing of two hundred rows by one
  /// person makes one request rather than two hundred.
  final Set<String> _asking = {};

  /// Told when anything new is known, so whatever is drawing can redraw.
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changed => _changed.stream;

  /// Where the network may be reached. Replaceable so a test can answer
  /// without one: what the real one returns depends on a service being up.
  Future<List<int>?> Function(Uri url) fetch = _get;

  /// The key Gravatar is built on: the address, trimmed and lowercased, as
  /// MD5. Not a secret and not used as one — it is a lookup, and the service
  /// defines it this way.
  static String keyOf(String email) =>
      md5.convert(email.trim().toLowerCase().codeUnits).toString();

  /// Where a picture of this person might be, best first.
  ///
  /// **Gravatar alone is not enough any more, and that is measurable.** Of the
  /// sixteen people who last touched the Flutter repository, not one has a
  /// Gravatar; fifteen of them commit as `<id>+<login>@users.noreply.github.com`,
  /// which is what GitHub hands out when somebody hides their address. Asking
  /// Gravatar about those is asking the wrong service.
  ///
  /// But that address *is* the answer: it carries the person's GitHub number,
  /// and GitHub serves the picture at a fixed url. So the address is read
  /// rather than looked up — no API, no token, no account, and still nothing
  /// the plugin can steer.
  static List<Uri> sourcesFor(String email) {
    final address = _normal(email);
    if (address.isEmpty) return const [];

    const github = 'users.noreply.github.com';
    if (address.endsWith('@$github')) {
      final who = address.substring(0, address.length - github.length - 1);
      final plus = who.indexOf('+');
      // `1063596+reidbaker` — the number is the account, and the number is
      // what GitHub keys its pictures on.
      final id = plus > 0 ? who.substring(0, plus) : '';
      if (id.isNotEmpty && int.tryParse(id) != null) {
        return [Uri.parse('https://avatars.githubusercontent.com/u/$id?s=64')];
      }
      // The older form is just the login, which GitHub also answers to.
      final login = plus > 0 ? who.substring(plus + 1) : who;
      if (login.isNotEmpty) {
        return [
          Uri.parse('https://avatars.githubusercontent.com/$login?s=64'),
        ];
      }
    }

    // Anybody else: the one service that is keyed on an address alone. `d=404`
    // is the difference between a picture of somebody and a picture of nobody
    // — without it it answers with a generated shape, which is worse than the
    // initials it would be covering up.
    return [
      Uri.parse('https://www.gravatar.com/avatar/${keyOf(address)}?s=64&d=404'),
    ];
  }

  /// The picture for [email] if it is already here, without asking for it.
  /// Null means "not yet" *or* "there is none", and the caller draws initials
  /// either way — the difference does not change what is on screen.
  File? cached(String email) => _known[_normal(email)];

  /// Makes sure [email] has been asked about. Returns at once; anything found
  /// arrives on [changed].
  void want(String email) {
    final address = _normal(email);
    if (address.isEmpty || _known.containsKey(address)) return;
    if (!_asking.add(address)) return;
    unawaited(_look(address));
  }

  Future<void> _look(String address) async {
    final key = keyOf(address);
    try {
      final where = home ??= Directory(
        '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}avatars',
      );
      final file = File('${where.path}${Platform.pathSeparator}$key.png');

      if (await file.exists()) {
        _settle(address, file);
        return;
      }

      List<int>? bytes;
      for (final source in sourcesFor(address)) {
        bytes = await fetch(source);
        if (bytes != null && bytes.isNotEmpty) break;
      }
      if (bytes == null || bytes.isEmpty) {
        _settle(address, null);
        return;
      }

      await where.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      _settle(address, file);
    } on Object {
      // No network, no disk, no service: there is no picture, and that is all
      // anybody drawing a row needs to know.
      _settle(address, null);
    }
  }

  void _settle(String address, File? file) {
    _asking.remove(address);
    _known[address] = file;
    if (!_changed.isClosed) _changed.add(null);
  }

  static String _normal(String email) => email.trim().toLowerCase();

  static Future<List<int>?> _get(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        // A picture of a person is a few kilobytes. Anything much larger is
        // not one, and is not worth the memory of finding out.
        if (bytes.length > 512 * 1024) return null;
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }
}
