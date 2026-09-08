import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/security/secret_store.dart';
import '../../core/settings/connection_store.dart';
import '../../state/window_stack.dart';
import '../widgets/x_button.dart';
import '../windows/window_dialogs.dart';
import 'common_dialogs.dart';

/// The saved connection list: open, edit or delete.
Future<void> showConnectionManager(
  BuildContext context, {
  required ConnectionStore store,
  required Future<void> Function(SavedConnection connection) onOpen,
  required Future<void> Function(SavedConnection connection) onEdit,
}) {
  return showDeskWindow<void>(
    context,
    id: 'connections',
    title: tr('Connections'),
    icon: Icons.dns_outlined,
    modal: false,
    preferredSize: const Size(620, 460),
    minSize: const Size(420, 300),
    builder: (window) => _ConnectionManagerView(
      store: store,
      onOpen: onOpen,
      onEdit: onEdit,
      window: window,
    ),
  );
}

class _ConnectionManagerView extends StatefulWidget {
  const _ConnectionManagerView({
    required this.store,
    required this.onOpen,
    required this.onEdit,
    required this.window,
  });

  final ConnectionStore store;
  final Future<void> Function(SavedConnection connection) onOpen;
  final Future<void> Function(SavedConnection connection) onEdit;
  final DeskWindow window;

  @override
  State<_ConnectionManagerView> createState() => _ConnectionManagerViewState();
}

class _ConnectionManagerViewState extends State<_ConnectionManagerView> {
  @override
  Widget build(BuildContext context) {
    final connections = widget.store.all;

    return WindowForm(
      actions: [
        TextButton(
          onPressed: widget.window.close,
          child: Text(tr('Close')),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: connections.isEmpty
                ? Center(child: Text(tr('No saved connections')))
                : ListView.builder(
                    itemCount: connections.length,
                    itemBuilder: (context, index) =>
                        _tile(context, connections[index]),
                  ),
          ),
          const Divider(height: 20),
          // Where the file lives, because it is meant to be editable and
          // people back these up.
          Text(
            widget.store.directoryPath ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, SavedConnection connection) {
    final stored = connection.hasStoredPassword;
    // A password saved under another Windows account cannot be read back here,
    // and saying so beats a connection that silently fails to authenticate.
    final unreadable = stored && connection.revealPassword() == null;

    return ListTile(
      leading: const Icon(Icons.dns_outlined),
      title: Text(connection.name),
      subtitle: Text(
        [
          '${connection.scheme}://${connection.summary}',
          if (unreadable)
            tr('Saved password belongs to another account')
          else if (stored)
            tr('Password saved')
          else
            tr('Asks for the password'),
        ].join('  ·  '),
        maxLines: 2,
      ),
      onTap: () async {
        widget.window.close();
        await widget.onOpen(connection);
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          XButton(
            icon: Icons.edit_outlined,
            tooltip: tr('Edit'),
            shape: XButtonShape.bare,
            height: 26,
            iconSize: 16,
            onPressed: () async {
              widget.window.close();
              await widget.onEdit(connection);
            },
          ),
          XButton(
            icon: Icons.delete_outline,
            tooltip: tr('Delete'),
            shape: XButtonShape.bare,
            height: 26,
            iconSize: 16,
            onPressed: () async {
              final go = await confirm(
                context,
                title: tr('Delete "{name}"', {'name': connection.name}),
                message: tr(
                  'The saved connection is removed from {file}.',
                  {'file': connection.storeFile},
                ),
                confirmLabel: tr('Delete'),
                destructive: true,
              );
              if (!go) return;
              await widget.store.delete(connection);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      isThreeLine: false,
    );
  }
}

/// Explains, in one line, how passwords are handled here.
String describePasswordStorage() => SecretStore.explanation;
