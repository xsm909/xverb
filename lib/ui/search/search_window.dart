import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/search/file_search.dart';
import '../../core/vfs/file_entry.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';
import '../../state/file_search_controller.dart';
import '../../state/window_stack.dart';
import '../format.dart';

/// Opens the search window — Total Commander's Alt+F7.
///
/// Modeless on purpose: a search of a big tree takes a while, and the panels
/// stay usable while it runs. There is only ever one, so asking again brings
/// the running search forward rather than starting a second one.
Future<void> showSearchWindow(BuildContext context) {
  final app = context.read<AppState>();
  return app.windows.open(DeskWindow(
    id: 'search',
    title: tr('Find files'),
    icon: Icons.search,
    preferredSize: const Size(880, 620),
    // Tall enough that the form always fits with a usable result list under it.
    minSize: const Size(560, 480),
    builder: (_) => const SearchView(),
  ));
}

/// The search form and its results.
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  late final AppState _app = context.read<AppState>();
  late final FileSearchController _search =
      FileSearchController(_app.fileSystems);

  final TextEditingController _mask = TextEditingController();
  final TextEditingController _text = TextEditingController();

  bool _subdirectories = true;
  bool _caseSensitive = false;
  bool _wholeWords = false;

  /// Where the search starts. Seeded from the active panel, and re-seeded by
  /// the "Use the current folder" button rather than silently following it.
  VfsPath? _location;

  @override
  void initState() {
    super.initState();
    _location = _app.active.location;
    _search.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    _mask.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _start() {
    final location = _location;
    if (location == null) return;

    _search.start(SearchQuery(
      location: location,
      namePattern: _mask.text,
      containingText: _text.text,
      caseSensitive: _caseSensitive,
      wholeWords: _wholeWords,
      searchSubdirectories: _subdirectories,
    ));
  }

  /// Hands the results to the active panel, the way Total Commander's
  /// "Feed to listbox" does. The window stays open, so the list can be fed
  /// again after being browsed away from.
  void _feedToPanel() {
    final query = _search.query;
    if (query == null || _search.results.isEmpty) return;

    _app.active.showResults(
      _search.results,
      label: tr('Search: {what}', {'what': query.summary}),
      origin: query.location,
    );
  }

  /// Jumps the active panel to the folder a result lives in and puts the
  /// cursor on it.
  Future<void> _goTo(FileEntry entry) async {
    final parent = entry.path.parent;
    if (parent == null) return;
    final panel = _app.active;
    await panel.navigateTo(parent);
    panel.findMatches(entry.name);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _form(context),
        const Divider(height: 1),
        Expanded(child: _results(context)),
        _statusLine(context),
      ],
    );
  }

  Widget _form(BuildContext context) {
    final location = _location;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _mask,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('Search for'),
                    hintText: tr('*.dart *.yaml | *.g.dart'),
                    helperText: tr('Masks, or a word to match anywhere in the name'),
                  ),
                  onSubmitted: (_) => _start(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _text,
                  decoration: InputDecoration(
                    labelText: tr('Containing text'),
                    hintText: tr('optional'),
                    helperText: tr('Leave empty to search by name only'),
                  ),
                  onSubmitted: (_) => _start(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        location?.display ?? tr('No folder'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _location = _app.active.location,
                      ),
                      child: Text(tr('Use the current folder')),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // A fixed row rather than a Wrap: the form has to keep the same
          // height at every window width, or narrowing the window would push
          // the results list out of the bottom of it.
          Row(
            children: [
              _check(tr('Subdirectories'), _subdirectories,
                  (v) => setState(() => _subdirectories = v)),
              _check(tr('Case sensitive'), _caseSensitive,
                  (v) => setState(() => _caseSensitive = v)),
              _check(tr('Whole words'), _wholeWords,
                  (v) => setState(() => _wholeWords = v)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _search.isRunning || location == null ? null : _start,
                icon: const Icon(Icons.search, size: 18),
                label: Text(tr('Start')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _search.isRunning ? _search.stop : null,
                icon: const Icon(Icons.stop, size: 18),
                label: Text(tr('Stop')),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed:
                    _search.results.isEmpty ? null : _feedToPanel,
                icon: const Icon(Icons.list_alt, size: 18),
                label: Text(tr('Feed to panel')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return Expanded(
      child: CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: value,
        onChanged: (v) => onChanged(v ?? false),
      ),
    );
  }

  Widget _results(BuildContext context) {
    final results = _search.results;

    if (results.isEmpty) {
      return Center(
        child: Text(
          _search.isRunning
              ? tr('Searching…')
              : _search.isFinished
                  ? tr('Nothing matched.')
                  : tr('Enter a mask and press Start.'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return ListView.builder(
      itemCount: results.length,
      itemExtent: 42,
      itemBuilder: (context, index) {
        final entry = results[index];
        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined,
            size: 18,
          ),
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            entry.path.parent?.display ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: entry.isDirectory
              ? null
              : Text(
                  formatSize(entry.size),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
          onTap: () => unawaited(_goTo(entry)),
        );
      },
    );
  }

  Widget _statusLine(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.query;

    final parts = <String>[
      tr('{count} found', {'count': _search.resultCount}),
      tr('{count} scanned', {'count': _search.scanned}),
      if (_search.failures > 0)
        tr('{count} unreadable', {'count': _search.failures}),
      if (_search.hitLimit) tr('limit reached'),
    ];

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          if (_search.isRunning)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          if (_search.isRunning) const SizedBox(width: 8),
          Text(parts.join('  ·  '), style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _search.isRunning
                  ? _search.currentDirectory?.display ?? ''
                  : query?.summary ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
