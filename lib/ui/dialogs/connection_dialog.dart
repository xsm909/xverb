import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/security/secret_store.dart';
import '../../core/settings/connection_store.dart';
import '../../state/app_state.dart';
import '../../state/window_stack.dart';
import '../widgets/context_menu.dart';
import '../windows/window_dialogs.dart';
import 'plugin_form.dart';
import '../widgets/hint.dart';

/// What the dialog produced.
class ConnectionResult {
  const ConnectionResult({
    required this.connection,
    required this.password,
    required this.storePassword,
  });

  final SavedConnection connection;

  /// Typed in this session. Only written to disk when [storePassword] is set
  /// and the platform can protect it.
  final String? password;
  final bool storePassword;
}

/// The connection form, built entirely from a plugin's [ConnectionSpec].
///
/// The core knows nothing about FTP; it knows how to render text, password,
/// number and switch fields, and hands the answers back. That is what lets a
/// transport ship a proper connection dialog without shipping any UI.
Future<ConnectionResult?> showConnectionDialog(
  BuildContext context, {
  required ConnectionSpec spec,
  SavedConnection? existing,
}) {
  return showDeskWindow<ConnectionResult>(
    context,
    id: 'connection:${spec.id}',
    title: tr('{name}: connection details', {'name': spec.title}),
    icon: Icons.dns_outlined,
    preferredSize: const Size(560, 560),
    minSize: const Size(420, 320),
    builder: (window) => _ConnectionForm(
      spec: spec,
      existing: existing,
      window: window,
    ),
  );
}

class _ConnectionForm extends StatefulWidget {
  const _ConnectionForm({
    required this.spec,
    required this.window,
    this.existing,
  });

  final ConnectionSpec spec;
  final SavedConnection? existing;
  final DeskWindow window;

  @override
  State<_ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<_ConnectionForm> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _flags = {};
  final TextEditingController _name = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _browsing = false;

  /// One key per browsable field, so the menu can open under *that* input.
  /// Taking the rect from the state's own context anchors it to the whole
  /// form, which put the menu at the top of the window instead.
  final Map<String, GlobalKey> _fieldKeys = {};

  /// What the last browse found, and which field asked for it. Held here
  /// rather than shown in a menu: a menu is a route, and pushing one takes the
  /// window layer down with it — the form itself vanished, taking the state
  /// that was meant to receive the answer.


  /// The picker floats in the root overlay, anchored to the field.
  ///
  /// Not a route — pushing one takes the window layer down and the form with
  /// it. Not inline content either: the field is near the bottom of a window,
  /// so a list that pushes the form taller opens where nobody is looking.

  bool _storePassword = false;
  bool _revealPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';

    for (final field in widget.spec.fields) {
      if (field.key == ConnectionSpec.passwordKey) continue;
      if (field.type == PluginFieldType.boolean) {
        _flags[field.key] = existing != null
            ? existing.flag(field.key, fallback: field.defaultValue == true)
            : field.defaultValue == true;
      } else {
        _text[field.key] = TextEditingController(
          text: existing?[field.key] ?? field.defaultValue?.toString() ?? '',
        );
      }
    }

    if (existing != null && existing.hasStoredPassword) {
      _storePassword = true;
      // A password that cannot be decrypted here belongs to another account;
      // leave the box empty rather than pretending we have it.
      _password.text = existing.revealPassword() ?? '';
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  bool _isHidden(PluginField field) {
    final key = field.hiddenWhen;
    return key != null && (_flags[key] ?? false);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('Give the session a name.'));
      return;
    }

    for (final field in widget.spec.fields) {
      if (!field.required || _isHidden(field)) continue;
      if (field.key == ConnectionSpec.passwordKey) continue;
      final value = _text[field.key]?.text.trim() ?? '';
      if (value.isEmpty) {
        setState(
          () => _error = tr('{field} is required.', {'field': field.label}),
        );
        return;
      }
    }

    final values = <String, String>{
      for (final entry in _text.entries)
        if (entry.value.text.trim().isNotEmpty)
          entry.key: entry.value.text.trim(),
      for (final entry in _flags.entries) entry.key: entry.value.toString(),
    };

    widget.window.close(ConnectionResult(
      connection: SavedConnection(
        name: name,
        specId: widget.spec.id,
        scheme: widget.spec.scheme,
        storeFile: widget.spec.storeFile,
        values: values,
      ),
      password: _password.text.isEmpty ? null : _password.text,
      storePassword: _storePassword && SecretStore.isSupported,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return WindowForm(
      onSubmit: _submit,
      actions: [
        TextButton(
          onPressed: widget.window.close,
          child: Text(tr('Cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr('OK'))),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabelledField(
              label: tr('Session'),
              child: TextField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr('A name for this connection'),
                ),
              ),
            ),
            for (final field in widget.spec.fields)
              if (!_isHidden(field)) _buildField(field),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(PluginField field) {
    if (field.key == ConnectionSpec.passwordKey) return _buildPassword(field);

    final isPath = field.type == PluginFieldType.remotePath;
    return PluginFieldInput(
      field: field,
      controller: _text[field.key],
      flag: _flags[field.key] ?? false,
      choice: _text[field.key]?.text,
      inputKey:
          isPath ? _fieldKeys.putIfAbsent(field.key, GlobalKey.new) : null,
      onChanged: (value) => setState(() {
        if (value is bool) {
          _flags[field.key] = value;
        } else {
          _text[field.key]?.text = value?.toString() ?? '';
        }
      }),
      // A path on the far end is the one field nobody can be expected to type
      // from memory, so it gets a way to go and look. Doing that also proves
      // the address, the account and the password in one press — which is the
      // only test of a connection that means anything.
      suffix: !isPath
          ? null
          : Hint(
              message: tr('Browse the server'),
              child: IconButton(
                icon: _browsing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore, size: 18),
                onPressed: _browsing ? null : () => unawaited(_browse(field)),
              ),
            ),
    );
  }

  /// Offers what sits *beside* the current value, in the app's own menu.
  ///
  /// Beside, not inside: a field holding `temp` is asking which share, so the
  /// useful answer is the other shares. Listing the contents of `temp` instead
  /// gave an empty menu whenever a share held only files, which read as a dead
  /// button. Going deeper is done by choosing, then pressing again.
  ///
  /// Pressing it is also the only honest test of a connection: it uses the
  /// address, the account and the password exactly as the plugin will.
  Future<void> _browse(PluginField field) async {
    final controller = _text[field.key];
    if (controller == null) return;

    final current = controller.text.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final segments = current.isEmpty ? <String>[] : current.split('/');
    final parent = segments.length > 1
        ? segments.sublist(0, segments.length - 1).join('/')
        : '';

    setState(() {
      _browsing = true;
      _error = null;
    });

    try {
      final values = <String, String>{
        for (final entry in _text.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
        for (final entry in _flags.entries) entry.key: entry.value.toString(),
      };
      if (parent.isEmpty) {
        values.remove(field.key);
      } else {
        values[field.key] = parent;
      }

      final probe = SavedConnection(
        name: '',
        specId: widget.spec.id,
        scheme: widget.spec.scheme,
        storeFile: widget.spec.storeFile,
        values: values,
      );
      final path = probe.toPath(password: _password.text);
      final entries =
          await context.read<AppState>().fileSystems.resolve(path).list(path);
      if (!mounted) return;

      final folders = entries.where((e) => e.isDirectory).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (folders.isEmpty) {
        // Said out loud. Silence here reads as a dead button, and the
        // difference between "nothing there" and "it did not work" matters.
        setState(() => _error = parent.isEmpty
            ? tr('The server offered nothing to browse.')
            : tr('Nothing inside {folder}.', {'folder': parent}));
        return;
      }

      final box = _fieldKeys[field.key]?.currentContext?.findRenderObject()
          as RenderBox?;
      final anchor = box == null || !box.hasSize
          ? (context.findRenderObject() as RenderBox).localToGlobal(
                Offset.zero,
              ) &
              Size.zero
          : box.localToGlobal(Offset.zero) & box.size;

      await showAppContextMenu(
        context: context,
        anchorRect: anchor,
        searchHint: tr('Search shares'),
        nodes: [
          for (final entry in folders)
            MenuItem(
              entry.name,
              icon: entry.isHidden
                  ? Icons.folder_off_outlined
                  : Icons.folder_outlined,
              checked: entry.name == segments.lastOrNull,
              onSelected: () {
                if (!mounted) return;
                setState(() {
                  controller.text =
                      parent.isEmpty ? entry.name : '$parent/${entry.name}';
                  _error = null;
                });
              },
            ),
        ],
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _browsing = false);
    }
  }

  Widget _buildPassword(PluginField field) {
    final canStore = SecretStore.isSupported;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabelledField(
          label: field.label,
          child: TextField(
            controller: _password,
            obscureText: !_revealPassword,
            decoration: InputDecoration(
              hintText: field.hint,
              suffixIcon: Hint(
                            message: _revealPassword ? tr('Hide') : tr('Show'),
                            child: IconButton(
                  icon: Icon(_revealPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () =>
                      setState(() => _revealPassword = !_revealPassword),
                ),
                          ),
            ),
          ),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(tr('Save the password')),
          // The honest version of Total Commander's warning: rather than
          // storing it in the clear and telling the user it is insecure, it is
          // either encrypted for this account or not stored at all.
          subtitle: Text(SecretStore.explanation),
          value: _storePassword && canStore,
          onChanged: canStore
              ? (value) => setState(() => _storePassword = value ?? false)
              : null,
        ),
        if (!_storePassword || !canStore)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              tr('You will be asked for it each time you connect.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Asks for a password at connect time, for connections that keep none.
Future<String?> promptForPassword(
  BuildContext context,
  SavedConnection connection,
) {
  final controller = TextEditingController();

  return showDeskWindow<String>(
    context,
    id: 'password:${connection.name}',
    title: connection.name,
    icon: Icons.password_outlined,
    preferredSize: const Size(460, 190),
    minSize: const Size(340, 170),
    builder: (window) => WindowForm(
      onSubmit: () => window.close(controller.text),
      actions: [
        TextButton(onPressed: window.close, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: () => window.close(controller.text),
          child: Text(tr('Connect')),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(
            labelText: tr('Password for {what}', {'what': connection.summary}),
          ),
          onSubmitted: window.close,
        ),
      ),
    ),
  );
}
