import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/catalogue_cache.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../core/plugins/plugin_source.dart';
import '../../core/plugins/rpc/python_installer.dart';
import '../../core/plugins/rpc/python_runtime.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/shell_open.dart';
import '../dialogs/common_dialogs.dart';
import '../dialogs/plugin_settings_dialog.dart';
import '../notice.dart';
import '../plugins/plugin_icons.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import '../text_scale.dart';
import 'plugin_log_console.dart';
import 'settings_group.dart';
import '../widgets/title_bar_plugins.dart';
import '../widgets/x_button.dart';
import '../widgets/hint.dart';

/// The collection the app knows about without being told. A constant rather
/// than a stored setting, so it cannot be lost and needs no migration.
const String kBuiltInPluginSource = 'xsm909/xverb-plugins';

/// The plugin manager: one feed of everything, searchable.
///
/// Installed, bundled and available extensions share a single list rather than
/// sitting in sections of their own. Sections read tidily until you are looking
/// for something — then you have to know which one it is in before you can
/// find it, and the answer depends on whether you happen to have installed it.
/// One list with a search box asks nothing of the person using it.
class PluginsTab extends StatefulWidget {
  const PluginsTab({super.key});

  @override
  State<PluginsTab> createState() => _PluginsTabState();
}

class _PluginsTabState extends State<PluginsTab> {
  final TextEditingController _search = TextEditingController();
  final List<_SourceResult> _sources = [];
  final Set<String> _installing = {};
  bool _loading = false;

  /// Whether the log at the bottom is open. A console shows its last line
  /// whatever else is going on; the rest is asked for.
  bool _logOpen = false;

  /// Which category is open, by name. **One at a time and none to begin with**,
  /// the shape the Appearance page was given the same day. Searching ignores
  /// it: a search is a question about everything, not about wherever you happen
  /// to be standing.
  String? _open;

  /// When each source was last actually asked, for the line that says so.
  DateTime? _asOf;

  @override
  void initState() {
    super.initState();
    // **What was remembered first, and the network only if it is stale.** This
    // used to fetch a whole repository tarball per source on the first frame,
    // so the list arrived late, an update was news only after a wait, and
    // opening the tab with no connection showed nothing at all. See
    // [CatalogueCache] for why the cache is a shallow copy of the repository
    // rather than a file of fields.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open_()));
  }

  /// Show what is remembered, then ask again if it is old.
  Future<void> _open_() async {
    final stale = await _loadCached();
    if (stale && mounted) await _refresh();
  }

  /// Reads every source out of the cache. Returns whether any of them is old
  /// enough to be worth asking about again — or was never there at all.
  Future<bool> _loadCached() async {
    var stale = false;
    final results = <_SourceResult>[];
    DateTime? oldest;

    for (final address in _addresses) {
      final cached = await CatalogueCache.read(address);
      if (cached == null) {
        stale = true;
        continue;
      }
      if (cached.isStale) stale = true;
      if (oldest == null || cached.fetchedAt.isBefore(oldest)) {
        oldest = cached.fetchedAt;
      }
      results.add(_SourceResult(address: address, remembered: cached));
    }

    if (!mounted || results.isEmpty) return stale;
    setState(() {
      _sources
        ..clear()
        ..addAll(results);
      _asOf = oldest;
    });
    return stale;
  }

  @override
  void dispose() {
    _search.dispose();
    for (final source in _sources) {
      unawaited(source.catalogue?.dispose() ?? Future<void>.value());
    }
    super.dispose();
  }

  List<String> get _addresses => [
        kBuiltInPluginSource,
        ...context.read<SettingsStore>().pluginSources,
      ];

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);

    final results = <_SourceResult>[];
    for (final address in _addresses) {
      try {
        final catalogue = await PluginSource.fetch(address);
        // Remembered before it is shown, so a fetch that is followed by the
        // window closing still leaves the answer behind.
        await CatalogueCache.write(address, catalogue);
        results.add(_SourceResult(address: address, catalogue: catalogue));
      } on Object catch (e) {
        // **What was remembered survives a failed fetch.** A source that is
        // unreachable this minute is not a source with nothing in it, and a
        // list that empties itself when the network drops is worse than one
        // that is out of date and says so.
        final kept = _sources.where((s) => s.address == address).firstOrNull;
        results.add(_SourceResult(
          address: address,
          error: '$e',
          remembered: kept?.remembered,
        ));
      }
    }

    if (!mounted) {
      for (final result in results) {
        await result.catalogue?.dispose();
      }
      return;
    }

    final old = [..._sources];
    setState(() {
      _sources
        ..clear()
        ..addAll(results);
      _loading = false;
      if (results.any((r) => r.catalogue != null)) _asOf = DateTime.now();
    });
    for (final result in old) {
      await result.catalogue?.dispose();
    }
  }

  Future<void> _addSource() async {
    final address = await promptForText(
      context,
      title: tr('Add a plugin source'),
      hint: tr('owner/name, or the address from the browser'),
      confirmLabel: tr('Add'),
    );
    if (address == null || address.trim().isEmpty || !mounted) return;
    await context.read<SettingsStore>().addPluginSource(address);
    if (mounted) await _refresh();
  }

  /// Installs a plugin, new or a later version of one already there, and says
  /// so when it does not work.
  ///
  /// The order of it — stop, replace, discover, start — belongs to the
  /// registry: a plugin that is only copied and discovered contributes nothing
  /// until the app is relaunched. [replacing] is here for the wording of the
  /// failure and nothing else.
  Future<void> _install(
    CatalogueEntry entry,
    PluginRegistry registry, {
    bool replacing = false,
  }) async {
    final id = entry.manifest.id;

    setState(() => _installing.add(id));
    try {
      // **A remembered description is not the plugin.** The cache holds
      // manifests and icons so the list can be a list on arrival; the code is
      // still at the source, so pressing Install goes and gets it. One press,
      // one download — this entry's source and not all of them.
      if (entry.metadataOnly) {
        final fetched = await _fetchAgain(entry);
        final real = fetched?.entries
            .where((e) => e.manifest.id == id)
            .firstOrNull;
        if (real == null) {
          await fetched?.dispose();
          if (mounted) {
            showNotice(context, tr('Could not reach the source of {name}',
                {'name': entry.manifest.displayName}));
          }
          return;
        }
        try {
          await registry.install(real);
        } finally {
          await fetched!.dispose();
        }
      } else {
        await registry.install(entry);
      }
    } on Object catch (e) {
      if (mounted) {
        showNotice(
          context,
          replacing
              ? tr('Could not update {name}: {error}',
                  {'name': entry.manifest.displayName, 'error': e})
              : tr('Could not install {name}: {error}',
                  {'name': entry.manifest.displayName, 'error': e}),
        );
      }
    } finally {
      if (mounted) setState(() => _installing.remove(id));
    }
  }

  /// The source fetched for real, for a plugin the cache only described.
  ///
  /// The **catalogue** comes back rather than the entry, and the caller
  /// disposes it once the install is done — the entry points into the extracted
  /// tree, so throwing that away before the copy is made would hand the
  /// registry a folder that is no longer there. Written the wrong way round
  /// first, with the dispose in a `finally`, which deletes it on the way out of
  /// this function and therefore always too early.
  Future<Catalogue?> _fetchAgain(CatalogueEntry entry) async {
    final address = _sources
        .where((s) => s.entries.any((e) => e.manifest.id == entry.manifest.id))
        .map((s) => s.address)
        .firstOrNull;
    if (address == null) return null;

    try {
      final fetched = await PluginSource.fetch(address);
      await CatalogueCache.write(address, fetched);
      return fetched;
    } on Object {
      return null;
    }
  }

  /// Installed and bundled first, then what is on offer.
  List<FeedItem> _feed(PluginRegistry registry) => buildPluginFeed(
        installed: registry.entries,
        offered: {
          for (final source in _sources) source.address: source.entries,
        },
        query: _search.text,
        runtimeVersion: registry.runtime?.version,
      );

  Future<void> _remove(FeedItem item, PluginRegistry registry) async {
    final name = item.manifest.displayName;

    // **What "remove" means depends on what is behind it.** Both extensions
    // that ship in the app bundle are also published in the plugins repository
    // under the same id, so anybody who has ever pressed Install has a folder
    // standing in front of one — and deleting that folder does not remove the
    // plugin, it uncovers the shipped copy — which reads as a Remove button
    // that does nothing. It works; it was saying the wrong thing about what it
    // does.
    final shipped = registry.shippedBehind(item.manifest.id);

    final go = await confirm(
      context,
      title: shipped == null
          ? tr('Remove {name}', {'name': name})
          : tr('Go back to the bundled {name}', {'name': name}),
      message: shipped == null
          ? tr('Deletes the folder it was installed into. Nothing else on the machine is touched, and it can be installed again from its source.')
          : tr('This one ships with the application, so removing the installed copy leaves version {version} in its place rather than removing the extension. Switch it off to stop it running.',
              {'version': shipped.version}),
      confirmLabel: shipped == null ? tr('Remove') : tr('Go back'),
      destructive: shipped == null,
    );
    if (!go || !mounted) return;
    try {
      await registry.uninstall(item.manifest.id);
      if (mounted && shipped != null) {
        showNotice(
          context,
          tr('{name} is now the bundled version {version}.',
              {'name': name, 'version': shipped.version}),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        showNotice(context,
            tr('Could not remove {name}: {error}', {'name': name, 'error': e}));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<PluginRegistry>();
    final feed = _feed(registry);
    final failures = _sources.where((s) => s.error != null).toList();
    final searching = _search.text.trim().isNotEmpty;

    // Shown above the groups, not inside one: an update is news, and news a
    // person has to go looking for shelf by shelf is not news.
    final updatable = feed.where((i) => i.update != null).toList();

    // A group per category, in the order a name sorts. `buildPluginFeed` has
    // already applied the query, so under a search these hold what answered it.
    final byCategory = <String, List<FeedItem>>{};
    for (final item in feed) {
      byCategory.putIfAbsent(item.manifest.category, () => []).add(item);
    }
    final categories = byCategory.keys.toList()..sort();

    Widget rowFor(FeedItem item) => _FeedRow(
          item: item,
          query: _search.text,
          registry: registry,
          installing: _installing.contains(item.manifest.id),
          onInstall: () => unawaited(_install(item.available!, registry)),
          onUpdate: () => unawaited(
            _install(item.update!, registry, replacing: true),
          ),
          onRemove: () => unawaited(_remove(item, registry)),
        );

    // A column with the feed taking what is left and the log held under it.
    // The tab is inside a TabBarView, which is inside an Expanded, so the
    // height here is bounded — but only ever give this one flexible child: a
    // second one made the whole settings page lay out to nothing, silently
    // and with no exception to follow.
    return Column(
      children: [
        Expanded(
          child: SettingsRowMetrics(
            dense: true,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                _RuntimeCard(plugins: registry),
                _SearchRow(
                  controller: _search,
                  loading: _loading,
                  asOf: _asOf,
                  onChanged: (_) => setState(() {}),
                  onRefresh: () {
                    unawaited(registry.rescan());
                    unawaited(_refresh());
                  },
                  onAddSource: () => unawaited(_addSource()),
                ),
                _TitleBarOrder(registry: registry),
                if (updatable.isNotEmpty)
                  _UpdatesBanner(
                    items: updatable,
                    busy: updatable
                        .any((i) => _installing.contains(i.manifest.id)),
                    onUpdateAll: () async {
                      for (final item in updatable) {
                        await _install(item.update!, registry, replacing: true);
                      }
                    },
                  ),
                // **Searching flattens the groups.** A search that left the
                // folding in place would make the reader open things to see
                // what was found, which is the work the search was meant to
                // save; the category travels with the rows instead, so the
                // answer also says which shelf to go to next time.
                if (searching)
                  if (feed.isEmpty)
                    const _EmptyFeed(searching: true)
                  else
                    for (final name in categories) ...[
                      FoundIn(group: SettingsGroup(title: name, rows: const [])),
                      for (final item in byCategory[name]!) rowFor(item),
                    ]
                else if (categories.isEmpty)
                  const _EmptyFeed(searching: false)
                else
                  for (final name in categories)
                    SettingsGroupTile(
                      group: SettingsGroup(
                        title: name,
                        icon: _categoryIcon(name),
                        rows: [for (final item in byCategory[name]!) rowFor(item)],
                      ),
                      count: byCategory[name]!.length,
                      open: _open == name,
                      onPressed: () => setState(
                        () => _open = _open == name ? null : name,
                      ),
                    ),
                if (failures.isNotEmpty)
                  _SourceFailures(
                    failures: failures,
                    onRetry: () => unawaited(_refresh()),
                  ),
                _Footer(plugins: registry),
              ],
            ),
          ),
        ),
        PluginLogConsole(
          plugins: registry,
          expanded: _logOpen,
          onToggle: () => setState(() => _logOpen = !_logOpen),
        ),
      ],
    );
  }
}

/// A shape for a shelf. The categories are a short, known list — a manifest
/// that names something else falls back to the plain one rather than being
/// argued with.
IconData _categoryIcon(String category) => switch (category.toLowerCase()) {
      'viewers' => Icons.visibility_outlined,
      'file systems' || 'filesystems' => Icons.cloud_outlined,
      'tools' => Icons.build_outlined,
      'archives' => Icons.inventory_2_outlined,
      'appearance' => Icons.palette_outlined,
      _ => Icons.extension_outlined,
    };

/// One line of the feed: a plugin, wherever it came from.
class FeedItem {
  FeedItem({
    required this.manifest,
    this.installed,
    this.available,
    this.update,
    this.sourceLabel,
    this.updated,
  });

  final PluginManifest manifest;
  final PluginEntry? installed;

  /// The offer to install this, for a plugin that is not installed yet.
  final CatalogueEntry? available;

  /// The offer to replace an installed plugin with a later version of itself.
  /// Null when what is installed is current, which is the usual case.
  final CatalogueEntry? update;

  /// Which source offered it.
  final String? sourceLabel;

  /// When it last changed upstream, when the repository said so.
  ///
  /// **What the catalogue says, whether or not this is installed.** It is only
  /// ever read to order the list, and the order must not depend on install
  /// state — see the sort at the end of [buildPluginFeed].
  final DateTime? updated;

  bool get isInstalled => installed != null;
}

/// Builds the feed from what is installed and what the sources offer.
///
/// A function of its inputs and nothing else, so the rules that are easy to
/// get wrong — which row wins, what counts as an update — can be checked
/// without a repository to download or a widget to pump.
@visibleForTesting
List<FeedItem> buildPluginFeed({
  required List<PluginEntry> installed,
  required Map<String, List<CatalogueEntry>> offered,
  String query = '',

  /// The interpreter the host would run a Python plugin on, right now. Handed
  /// in rather than remembered on the entries: installing Python has to make
  /// an offer takeable in the same frame — see [CatalogueEntry.blockedBecause].
  String? runtimeVersion,
}) {
  final items = <FeedItem>[];
  final have = <String, PluginEntry>{
    for (final entry in installed) entry.manifest.id: entry,
  };

  /// The best offer for an id: the latest version any source publishes.
  final byId = <String, ({CatalogueEntry entry, String source})>{};
  for (final source in offered.entries) {
    for (final entry in source.value) {
      final existing = byId[entry.manifest.id];
      if (existing != null &&
          PluginManifest.compareVersions(
                entry.manifest.version,
                existing.entry.manifest.version,
              ) <=
              0) {
        continue;
      }
      byId[entry.manifest.id] = (entry: entry, source: source.key);
    }
  }

  for (final entry in installed) {
    final offer = byId[entry.manifest.id];
    // A bundled extension has no folder of its own to replace, so an offer of
    // a newer one is not an update it can take.
    final isNewer = offer != null &&
        !entry.manifest.isBundled &&
        offer.entry.isInstallable(runtimeVersion) &&
        PluginManifest.compareVersions(
              offer.entry.manifest.version,
              entry.manifest.version,
            ) >
            0;
    items.add(FeedItem(
      manifest: entry.manifest,
      installed: entry,
      update: isNewer ? offer.entry : null,
      sourceLabel: isNewer ? offer.source : null,
      // The offer's date even when there is nothing to update to, because this
      // is the sort key and the sort key must be the same before and after
      // installing. It used to be null unless a newer version existed, so
      // installing something moved it from among the dated rows down to the
      // undated ones — a second way the list rearranged itself under the hand.
      updated: offer?.entry.updated,
    ));
  }

  for (final offer in byId.values) {
    if (have.containsKey(offer.entry.manifest.id)) continue;
    items.add(FeedItem(
      manifest: offer.entry.manifest,
      available: offer.entry,
      sourceLabel: offer.source,
      updated: offer.entry.updated,
    ));
  }

  final wanted = query.trim().toLowerCase();
  bool matches(FeedItem item) {
    if (wanted.isEmpty) return true;
    final manifest = item.manifest;
    return [
      manifest.displayName,
      manifest.id,
      ?manifest.displayDescription,
      ?manifest.author,
      for (final scheme in manifest.schemes) scheme.scheme,
    ].any((s) => s.toLowerCase().contains(wanted));
  }

  // **Nothing in this order depends on what is installed.**
  //
  // Installed rows used to sort to the top, so the row you
  // had just pressed left the place you pressed it and everything below it
  // slid. Installed-ness is a mark on a row, not a position: the one thing you
  // were sure of — where the plugin you just installed was — is exactly what
  // that took away.
  return items.where(matches).toList()
    ..sort((a, b) {
      // Newest first. A shelf people come back to should lead with what has
      // changed since they last looked, and only fall back to the alphabet
      // where the repository said nothing about when.
      final at = a.updated;
      final bt = b.updated;
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if (at != null && bt == null) return -1;
      if (at == null && bt != null) return 1;
      return a.manifest.displayName.toLowerCase().compareTo(
            b.manifest.displayName.toLowerCase(),
          );
    });
}

/// One source, as it stands: what it said just now, what it said last time, or
/// why it would not say anything.
class _SourceResult {
  _SourceResult({
    required this.address,
    this.catalogue,
    this.error,
    this.remembered,
  });

  final String address;

  /// Fetched this session, with the plugins themselves behind it.
  final Catalogue? catalogue;

  final String? error;

  /// What [CatalogueCache] had. Descriptions and icons; no plugins.
  final CachedCatalogue? remembered;

  /// What to list. The fresh answer wins; the remembered one stands in.
  List<CatalogueEntry> get entries =>
      catalogue?.entries ?? remembered?.entries ?? const [];
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.loading,
    required this.onChanged,
    required this.onRefresh,
    required this.onAddSource,
    this.asOf,
  });

  final TextEditingController controller;
  final bool loading;

  /// When the list was last actually asked for, or null when it has never been
  /// — said out loud because the list is now allowed to be *remembered*, and a
  /// list that might be six hours old should say which it is rather than let
  /// somebody read a missing update as no update.
  final DateTime? asOf;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;
  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
      child: Row(
        children: [
          // The same box the Appearance page is searched with, down to the
          // Escape that empties it.
          Expanded(
            child: SettingsSearchBox(
              controller: controller,
              onChanged: onChanged,
              hint: tr('Search plugins'),
            ),
          ),
          const SizedBox(width: 6),
          if (asOf != null && !loading)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                _said(asOf!),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Hint(
              message: tr('Check for updates and rescan'),
              child: IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: onRefresh,
              ),
            ),
          Hint(
            message: tr('Add a plugin source'),
            child: IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 18),
              onPressed: onAddSource,
            ),
          ),
        ],
      ),
    );
  }

  /// How old the list is, in the roundest terms that are still true. Nobody
  /// needs the minute; what they need is whether this was today.
  static String _said(DateTime when) {
    final age = DateTime.now().difference(when);
    if (age.inMinutes < 2) return tr('just now');
    if (age.inHours < 1) return tr('{n} min ago', {'n': '${age.inMinutes}'});
    if (age.inDays < 1) return tr('{n} h ago', {'n': '${age.inHours}'});
    return tr('{n} d ago', {'n': '${age.inDays}'});
  }
}

/// The icons in the title bar, in the order they sit there, with a way to
/// move each one along.
///
/// Ordering belongs here rather than in a plugin's own settings: the row is
/// shared, and no plugin can be asked where it should sit relative to another
/// it knows nothing about. Hidden entirely below two icons, where there is no
/// order to arrange.
class _TitleBarOrder extends StatelessWidget {
  const _TitleBarOrder({required this.registry});

  final PluginRegistry registry;

  @override
  Widget build(BuildContext context) {
    final commands = registry.titleBarCommands;
    if (commands.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('Title bar order'),
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < commands.length; i++)
                _OrderChip(
                  command: commands[i],
                  isFirst: i == 0,
                  isLast: i == commands.length - 1,
                  onMove: (by) => unawaited(
                    registry.moveTitleBarCommand(commands[i].spec.id, by),
                  ),
                ),
            ],
          ),
          if (commands.length > TitleBarPluginItems.maxVisible)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tr(
                  'The first {count} are shown as '
                  'icons; the rest are behind the … button.',
                  {'count': TitleBarPluginItems.maxVisible},
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _OrderChip extends StatelessWidget {
  const _OrderChip({
    required this.command,
    required this.isFirst,
    required this.isLast,
    required this.onMove,
  });

  final PluginCommand command;
  final bool isFirst;
  final bool isLast;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(pluginIcon(command.spec.icon), size: 15),
          const SizedBox(width: 6),
          Text(command.title, style: const TextStyle(fontSize: 12)),
          Hint(
            message: tr('Move left'),
            child: IconButton(
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left),
              onPressed: isFirst ? null : () => onMove(-1),
            ),
          ),
          Hint(
            message: tr('Move right'),
            child: IconButton(
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              onPressed: isLast ? null : () => onMove(1),
            ),
          ),
        ],
      ),
    );
  }
}

/// Says how many plugins have a later version waiting, and takes them all.
///
/// Above the shelves rather than in them: an update is news, and news you have
/// to go looking for shelf by shelf is not news. It names what is out of date
/// so pressing the button is not a leap of faith.
class _UpdatesBanner extends StatelessWidget {
  const _UpdatesBanner({
    required this.items,
    required this.busy,
    required this.onUpdateAll,
  });

  final List<FeedItem> items;
  final bool busy;
  final Future<void> Function() onUpdateAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = items.map((i) => i.manifest.displayName).join(', ');

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            Icons.system_update_alt,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  items.length == 1
                      ? tr('An update is available')
                      : tr('{count} updates are available', {
                          'count': items.length,
                        }),
                  style: TextStyle(
                    fontWeight: context.uiWeight(FontWeight.w600),
                  ),
                ),
                Text(names, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            XButton(
              label: items.length == 1 ? tr('Update') : tr('Update all'),
              height: 26,
              tone: XButtonTone.filled,
              onPressed: () => unawaited(onUpdateAll()),
            ),
        ],
      ),
    );
  }
}

/// One shelf, the way an app store lists its sections.
class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            searching
                ? tr('Nothing matches that.')
                : tr('No plugins yet. Add a source to see what is on offer.'),
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// Why a row answered the search, when the answer is not already on the row.
///
/// The feed matches on five things — the name, the id, the description, the
/// author and the schemes a plugin handles — and a row draws the first and one
/// of the middle two. So `ftp` finds the web plugin and the word appears
/// nowhere: a result you have to take on trust. Nothing in this application
/// asks that, and a list of plugins is no exception.
///
/// Null when the query is empty, or when it is already visible on the row.
@visibleForTesting
String? whyFound(PluginManifest manifest, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return null;

  bool holds(String? text) => text != null && text.toLowerCase().contains(needle);
  if (holds(manifest.displayName)) return null;
  if (holds(manifest.displayDescription ?? manifest.id)) return null;

  for (final scheme in manifest.schemes) {
    if (holds(scheme.scheme)) return '${scheme.scheme}://';
  }
  if (holds(manifest.author)) return manifest.author;
  // The id is only drawn when there is no description to draw instead.
  if (holds(manifest.id)) return manifest.id;
  return null;
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({
    required this.item,
    required this.query,
    required this.registry,
    required this.installing,
    required this.onInstall,
    required this.onUpdate,
    required this.onRemove,
  });

  final FeedItem item;

  /// What was typed in the box, so the row can say why it is one of the
  /// answers — see [_why].
  final String query;
  final PluginRegistry registry;
  final bool installing;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final manifest = item.manifest;
    final entry = item.installed;
    final theme = Theme.of(context);

    final detail = <String>[
      if (item.update != null) '${manifest.version} → '
          '${item.update!.manifest.version}',
      if (entry != null && entry.activeSchemes.isNotEmpty)
        entry.activeSchemes.map((s) => '$s://').join(', '),
      if (entry != null && entry.activeViewers.isNotEmpty)
        tr('{count} viewer(s)', {'count': entry.activeViewers.length}),
      if (item.sourceLabel != null)
        tr('from {source}', {'source': item.sourceLabel}),
    ].join(' · ');

    final problem = entry?.error ??
        item.available?.blockedBecause(registry.runtime?.version);
    final accent = appearanceOf(context).accentColor;
    final asked = query.trim();

    return ListTile(
      leading: _PluginIcon(manifest: manifest, state: entry?.state),
      title: Row(
        children: [
          Flexible(
            child: Text.rich(
              marked(manifest.displayName, asked, null, accent),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            manifest.isBundled ? 'bundled' : manifest.version,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          _RuntimeBadge(runtime: manifest.runtime),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            marked(
              manifest.displayDescription ?? manifest.id,
              asked,
              null,
              accent,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // **And where the match is in none of that, the row says where it
          // is.** The search looks in five places and only two of them are
          // drawn, so a plugin could answer `ftp` with the word nowhere on it
          // and look like a mistake. A search that finds something says why
          // it found it, here and everywhere else in the application.
          if (whyFound(manifest, asked) case final because?)
            Text.rich(
              marked(because, asked, theme.textTheme.bodySmall, accent),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (detail.isNotEmpty)
            Text(detail, style: theme.textTheme.bodySmall),
          if (problem != null)
            Text(
              problem,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
        ],
      ),
      isThreeLine: problem != null ||
          detail.isNotEmpty ||
          whyFound(manifest, asked) != null,
      trailing: _Actions(
        item: item,
        registry: registry,
        installing: installing,
        onInstall: onInstall,
        onUpdate: onUpdate,
        onRemove: onRemove,
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.item,
    required this.registry,
    required this.installing,
    required this.onInstall,
    required this.onUpdate,
    required this.onRemove,
  });

  final FeedItem item;
  final PluginRegistry registry;
  final bool installing;
  final VoidCallback onInstall;
  final VoidCallback onUpdate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (installing) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final available = item.available;
    if (available != null) {
      // The Row is load-bearing, not decoration. A ListTile hands `trailing`
      // the full tile width, and XButton's container has an alignment and no
      // width of its own, so under a bounded constraint it takes all of it —
      // which makes ListTile assert and takes the whole settings page down
      // with it. Wrapped in a min-size Row the width arrives unbounded and the
      // button shrinks to its label instead.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          XButton(
            label: tr('Install'),
            height: 26,
            outlined: true,
            onPressed: available.isInstallable(registry.runtime?.version)
                ? onInstall
                : null,
          ),
        ],
      );
    }

    final entry = item.installed!;
    final manifest = entry.manifest;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.update != null)
          XButton(
            label: tr('Update'),
            height: 26,
            tone: XButtonTone.filled,
            onPressed: onUpdate,
          ),
        // Only when there is something in the window: the plugin's own
        // settings, or the choice of where its commands appear. An icon that
        // opens an empty window teaches people not to press it.
        if (manifest.settings.isNotEmpty || manifest.commands.isNotEmpty)
          Hint(
            message: tr('Settings'),
            child: IconButton(
              icon: const Icon(Icons.tune, size: 18),
              onPressed: () => unawaited(showPluginSettings(
                context,
                manifest: manifest,
                registry: registry,
              )),
            ),
          ),
        // Restarting only means anything for a plugin with a process.
        if (manifest.runtime == PluginRuntime.python &&
            (entry.isActive || entry.state == PluginState.failed))
          Hint(
            message: tr('Restart'),
            child: IconButton(
              icon: const Icon(Icons.restart_alt, size: 18),
              onPressed: () => registry.restart(manifest.id),
            ),
          ),
        Switch(
          value: !registry.disabled.contains(manifest.id),
          onChanged: (value) => registry.setEnabled(manifest.id, value),
        ),
        // Bundled extensions have no folder of their own to delete; for those
        // the switch is what "remove" means. An *installed* copy standing in
        // front of a bundled one has a folder, and deleting it uncovers the
        // shipped version rather than removing anything — so the button says
        // that instead of promising a removal it cannot perform.
        if (!manifest.isBundled)
          Hint(
            message: registry.shippedBehind(manifest.id) == null
                ? tr('Remove')
                : tr('Go back to the bundled version'),
            child: IconButton(
              icon: Icon(
                registry.shippedBehind(manifest.id) == null
                    ? Icons.delete_outline
                    : Icons.settings_backup_restore,
                size: 18,
              ),
              onPressed: onRemove,
            ),
          ),
      ],
    );
  }
}

/// What the plugin is, at a glance, with how it is doing as a dot on top.
///
/// The icon says what it does rather than what state it is in: a list of
/// identical puzzle pieces tells you nothing, and state is a colour, which the
/// dot carries without taking the slot.
class _PluginIcon extends StatelessWidget {
  const _PluginIcon({required this.manifest, this.state});

  final PluginManifest manifest;
  final PluginState? state;


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = switch (state) {
      PluginState.active => Colors.green,
      PluginState.starting => Colors.orange,
      PluginState.failed => scheme.error,
      PluginState.incompatible || PluginState.unsupported => Colors.orange,
      PluginState.disabled || PluginState.discovered => Colors.grey,
      null => null,
    };

    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        children: [
          Center(
            child: Container(
              width: 34,
              height: 34,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: pluginArtwork(manifest, size: 34),
            ),
          ),
          if (dot != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tells at a glance whether an extension is code or data.
class _RuntimeBadge extends StatelessWidget {
  const _RuntimeBadge({required this.runtime});

  final PluginRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isData = runtime == PluginRuntime.declarative;
    final color = isData ? scheme.tertiary : scheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        runtime.label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: context.uiWeight(FontWeight.w700),
          color: color,
        ),
      ),
    );
  }
}

class _SourceFailures extends StatelessWidget {
  const _SourceFailures({required this.failures, required this.onRetry});

  final List<_SourceResult> failures;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              failures.length == 1
                  ? tr('Could not read {address}.',
                      {'address': failures.single.address})
                  : tr('{count} sources could not be read.',
                      {'count': failures.length}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onRetry, child: Text(tr('Retry'))),
        ],
      ),
    );
  }
}

/// The plugins directory, under the feed.
class _Footer extends StatelessWidget {
  const _Footer({required this.plugins});

  final PluginRegistry plugins;

  @override
  Widget build(BuildContext context) {
    final path = plugins.pluginsPath;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  path ?? tr('Resolving…'),
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Hint(
                message: tr('Copy path'),
                child: IconButton(
                  iconSize: 15,
                  icon: const Icon(Icons.copy),
                  onPressed: path == null
                      ? null
                      : () => Clipboard.setData(ClipboardData(text: path)),
                ),
              ),
              Hint(
                message: tr('Open the plugins folder'),
                child: IconButton(
                  iconSize: 15,
                  icon: const Icon(Icons.folder_open),
                  onPressed: path == null ? null : () => ShellOpen.open(path),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Python status, and the two ways to get one.
class _RuntimeCard extends StatefulWidget {
  const _RuntimeCard({required this.plugins});

  final PluginRegistry plugins;

  @override
  State<_RuntimeCard> createState() => _RuntimeCardState();
}

class _RuntimeCardState extends State<_RuntimeCard> {
  InstallProgress? _progress;
  String? _installError;

  PluginRegistry get plugins => widget.plugins;

  Future<void> _install() async {
    final go = await confirm(
      context,
      title: tr('Install {version}', {'version': PythonInstaller.pinnedLabel}),
      message: tr(
        'Plugins are written against one Python version, so the app runs its '
        'own rather than whichever one the machine happens to have.\n\n'
        '{url}\n\n'
        'Nothing is installed system-wide: no administrator rights, no PATH '
        'changes, and removing the folder removes it completely.',
        {'url': PythonInstaller.plannedUrl},
      ),
      confirmLabel: tr('Download'),
    );
    if (!go || !mounted) return;

    setState(() {
      _installError = null;
      _progress = InstallProgress(tr('Starting…'));
    });

    try {
      await PythonInstaller.install(
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      await plugins.refreshRuntime();
    } on Object catch (e) {
      if (mounted) setState(() => _installError = e.toString());
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<void> _chooseInterpreter() async {
    final path = await promptForText(
      context,
      title: tr('Use an existing interpreter'),
      hint: Platform.isWindows
          ? r'C:\Python312\python.exe'
          : '/usr/local/bin/python3.12',
      confirmLabel: tr('Use'),
    );
    if (path == null || path.trim().isEmpty) return;

    PythonRuntime.preferredPath = path.trim();
    await plugins.refreshRuntime();
    if (!mounted) return;
    setState(() {
      _installError = plugins.runtime == null
          ? PythonRuntime.lastError ??
              tr('That did not run as a Python {version} interpreter.', {
                'version': '${PythonInstaller.targetMajor}.'
                    '${PythonInstaller.targetMinor}',
              })
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtime = plugins.runtime;
    final theme = Theme.of(context);

    // Working and quiet about it: one line, so the feed starts higher up.
    if (runtime != null && _progress == null && _installError == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${tr('Python {version}', {'version': runtime.version})}'
                ' · ${runtime.executable}',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  runtime != null ? Icons.check_circle : Icons.error_outline,
                  color: runtime != null ? Colors.green : theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    runtime != null
                        ? tr('Python {version}', {'version': runtime.version})
                        : tr('Python runtime unavailable'),
                    style: TextStyle(
                      fontWeight: context.uiWeight(FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            if (plugins.runtimeProblem != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  plugins.runtimeProblem!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_installError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _installError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress!.fraction),
              const SizedBox(height: 4),
              Text(_progress!.message, style: theme.textTheme.bodySmall),
            ] else if (runtime == null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (PythonInstaller.isSupported)
                    XButton(
                      icon: Icons.download,
                      label: tr('Install Python'),
                      tone: XButtonTone.filled,
                      height: 28,
                      onPressed: _install,
                    ),
                  const SizedBox(width: 8),
                  XButton(
                    icon: Icons.folder_open,
                    label: tr('Use an existing one…'),
                    outlined: true,
                    height: 28,
                    onPressed: _chooseInterpreter,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                PythonInstaller.isSupported
                    ? tr(
                        'Plugins run on {version}, the same '
                        'version on every platform. The download is about '
                        '25 MB and lives in this app\'s folder only.',
                        {'version': PythonInstaller.pinnedLabel},
                      )
                    : tr(
                        'Plugins run on Python {version} or newer. No pinned '
                        'build is published for this machine, so point the app '
                        'at an interpreter you installed yourself.',
                        {
                          'version': '${PythonInstaller.targetMajor}.'
                              '${PythonInstaller.targetMinor}',
                        },
                      ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
