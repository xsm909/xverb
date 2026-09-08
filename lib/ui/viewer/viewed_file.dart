import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/viewer.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';

/// A file a plugin pointed at, drawn by whichever viewer claims it.
///
/// **This is the application answering its own question.** "Who can show a
/// `.png`" is what it works out every time somebody presses F3, and a tool
/// that wanted to show one had two bad choices before this: carry a decoder of
/// its own — and then a second one for the next format — or say "binary file"
/// and leave it there.
///
/// So a plugin says *where the file is* and stops. The host looks in its
/// registry, takes the viewer that claims the extension with the highest
/// priority — the same order F3 offers them in, so what a tool shows and what
/// F3 shows can never disagree — and draws whatever comes back. The tool does
/// not know which viewer that was, or that it exists at all; installing a
/// better image viewer improves every tool that ever pointed at an image.
class ViewedFile extends StatefulWidget {
  const ViewedFile({
    super.key,
    required this.url,
    required this.draw,
    this.viewers,
  });

  final String url;

  /// Who is asked which viewers claim an extension. The application's own
  /// register unless something hands over another — a seam for a test, and
  /// the only way to check that the right viewer is asked for rather than
  /// that some viewer answered.
  final List<RegisteredViewer> Function(String extension)? viewers;

  /// Draws what the viewer returned. Handed back rather than drawn here, so a
  /// file inside a tool looks exactly like the same file inside the viewer —
  /// there is one renderer for content and this is not a second one.
  final Widget Function(ViewerContent content) draw;

  @override
  State<ViewedFile> createState() => _ViewedFileState();
}

class _ViewedFileState extends State<ViewedFile> {
  ViewerContent? _content;

  /// Counts the reads, so a slow viewer answering after the cursor has moved
  /// on is dropped rather than painted over the file now being looked at.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ViewedFile old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _content = null;
      _load();
    }
  }

  /// The extension the registry is asked about, taken from the url's own name
  /// rather than from anything the plugin said. A file is what its name says
  /// it is, wherever it happens to live.
  static String _extensionOf(VfsPath path) {
    final name = path.name;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  Future<void> _load() async {
    final generation = ++_generation;

    final List<RegisteredViewer> candidates;
    final VfsPath path;
    try {
      path = VfsPath.parse(widget.url);
      final ask = widget.viewers ??
          (extension) => context.read<AppState>().plugins.viewersFor(
                extension,
                // A file named rather than typed — `LICENSE`, `Makefile` —
                // is claimed by its name or by nothing at all.
                name: path.name,
              );
      candidates = ask(_extensionOf(path));
    } on Object catch (e) {
      _settle(generation, ViewerContent.error('$e'));
      return;
    }

    if (candidates.isEmpty) {
      _settle(
        generation,
        ViewerContent.error(
          tr('Nothing here can show {name}. Install a viewer for it from '
              'Settings → Plugins.', {'name': path.name}),
        ),
      );
      return;
    }

    ViewerContent answer;
    try {
      answer = await candidates.first.open(path);
    } on Object catch (e) {
      answer = ViewerContent.error(tr('{name} failed: {error}',
          {'name': candidates.first.title, 'error': e}));
    }
    _settle(generation, answer);
  }

  void _settle(int generation, ViewerContent content) {
    if (!mounted || generation != _generation) return;
    setState(() => _content = content);
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    if (content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return widget.draw(content);
  }
}
