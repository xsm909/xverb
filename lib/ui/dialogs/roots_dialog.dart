import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/vfs/fs_provider.dart';
import '../../core/vfs/fs_registry.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/window_stack.dart';
import '../windows/window_dialogs.dart';

/// Lists every root offered by every registered provider — local drives first,
/// then whatever plugins contribute. Also accepts a URL typed by hand, which is
/// how a user reaches an `ftp://` or `smb://` location before bookmarking it.
Future<VfsPath?> showRootsDialog(
  BuildContext context,
  FileSystemRegistry registry,
) {
  return showDeskWindow<VfsPath>(
    context,
    id: 'roots',
    title: tr('Go to'),
    icon: Icons.place_outlined,
    preferredSize: const Size(520, 480),
    minSize: const Size(380, 300),
    builder: (window) => _RootsView(registry: registry, window: window),
  );
}

class _RootsView extends StatefulWidget {
  const _RootsView({required this.registry, required this.window});

  final FileSystemRegistry registry;
  final DeskWindow window;

  @override
  State<_RootsView> createState() => _RootsViewState();
}

class _RootsViewState extends State<_RootsView> {
  final TextEditingController _url = TextEditingController();
  late Future<List<VfsRoot>> _roots;

  @override
  void initState() {
    super.initState();
    _roots = widget.registry.allRoots();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submitUrl() {
    final text = _url.text.trim();
    if (text.isEmpty) return;
    final path =
        text.contains('://') ? VfsPath.parse(text) : VfsPath.local(text);
    widget.window.close(path);
  }

  @override
  Widget build(BuildContext context) {
    return WindowForm(
      onSubmit: _submitUrl,
      actions: [
        TextButton(
          onPressed: widget.window.close,
          child: Text(tr('Cancel')),
        ),
      ],
      child: Column(
        children: [
          TextField(
            controller: _url,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr('Path or URL'),
              hintText: tr('C:\\Users  ·  ftp://user@host/pub'),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _submitUrl,
              ),
            ),
            onSubmitted: (_) => _submitUrl(),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<VfsRoot>>(
              future: _roots,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final roots = snapshot.data!;
                if (roots.isEmpty) {
                  return Center(child: Text(tr('No roots available')));
                }
                return ListView.builder(
                  itemCount: roots.length,
                  itemBuilder: (context, index) {
                    final root = roots[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(_iconFor(root.iconName)),
                      title: Text(root.label),
                      subtitle: root.subtitle == null
                          ? null
                          : Text(
                              root.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => widget.window.close(root.path),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(String? name) => switch (name) {
        'drive' => Icons.storage,
        'home' => Icons.home_outlined,
        'folder' => Icons.folder_outlined,
        'server' => Icons.dns_outlined,
        'network' => Icons.lan_outlined,
        _ => Icons.place_outlined,
      };
}
