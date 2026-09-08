import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/settings_store.dart';
import 'about_tab.dart';
import 'appearance_tab.dart';
import 'plugins_tab.dart';

/// The three tabs of settings, without any chrome of their own.
///
/// Kept separate from [SettingsPage] so the tabs can be dropped into anything:
/// the page draws the title bar and the back button around them, and a test can
/// pump a single tab with nothing else at all.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  /// Which tab was last looked at.
  ///
  /// Deliberately outside the widget tree. Opening any window over the settings
  /// page — Install Python, a colour picker, a name prompt — moves the page to
  /// a different position in the tree, and Flutter discards the state of a
  /// widget that moved. A `TabController` living in this widget's state went
  /// with it, and the tab snapped back to Appearance mid-click. Kept here, the
  /// choice survives whatever the tree does.
  static int lastTab = 0;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: SettingsView.lastTab.clamp(0, 2),
  )..addListener(() => SettingsView.lastTab = _tabs.index);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watched for the language, not for the theme this row does not use. A
    // pushed page is not rebuilt when an ancestor is, so without this the tabs
    // kept the language they were built in while the page under them changed.
    context.watch<SettingsStore>();

    return KeyedSubtree(
      // The language is part of what identifies this subtree, so changing it
      // builds a new one.
      //
      // Watching the store is not enough on its own, and the settings page is
      // where that shows: the three tabs below are `const`, so they are the
      // same widget instances on every rebuild, and Flutter skips a subtree
      // whose widget has not changed. Appearance updated only because it
      // happens to watch the store itself; Plugins and About kept whatever
      // language they were first drawn in until the page was closed and
      // opened again — which is exactly what the user saw. A key here settles
      // it for every tab, including ones added later that nobody remembers to
      // make listen.
      key: ValueKey(activeLocalisation.code),
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: tr('Appearance')),
              Tab(text: tr('Plugins')),
              Tab(text: tr('About')),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [AppearanceTab(), PluginsTab(), AboutTab()],
            ),
          ),
        ],
      ),
    );
  }
}
