import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/view.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';
import '../../state/panel_attachment.dart';
import '../../state/panel_controller.dart';
import '../dialogs/common_dialogs.dart';
import '../dialogs/progress_dialog.dart';
import '../notice.dart';
import '../page_transition.dart';
import '../viewer/plugin_viewer_page.dart';
import 'plugin_view_page.dart';

/// Opens plugin views, and carries out what they ask the host for.
///
/// A view can be started from the Tools menu, from the title bar, from a
/// panel's location menu, or from a key binding — and the title bar is drawn on
/// pages that know nothing about the commander screen. Keeping the decision in
/// one object rather than in the screen is what lets all four behave the same.
/// What a view is called in a panel's location menu.
///
/// That menu is opened on one side to send *that* side somewhere, and a view
/// which follows the other panel is about to read the *opposite* one. "Git"
/// alone leaves the only question worth answering — which folder it is about
/// to be about — to be worked out from which of the two menus was opened.
///
/// A view that follows nothing reads no panel, so it says nothing about one.
String locationViewLabel(ViewSpec spec, {required bool targetIsLeft}) {
  if (spec.follows == ViewFollows.none) return spec.title;
  return tr(
    '{view} here, reading the {side} panel',
    {
      'view': spec.title,
      'side': targetIsLeft ? tr('right') : tr('left'),
    },
  );
}

class ViewLauncher {
  const ViewLauncher(this.app);

  final AppState app;

  /// Opens a view on the surface that suits where it was asked for.
  ///
  /// [panel] names one explicitly — the location menu sends a view to the
  /// panel whose menu it was. Without one the view goes full screen if it can,
  /// and into the active panel if a panel is the only surface it offers.
  Future<void> open(
    BuildContext context,
    RegisteredView view, {
    PanelController? panel,
    VoidCallback? onReturn,
  }) async {
    final surfaces = app.plugins.surfacesForView(view);

    // **Asked for while a panel is already holding it: make it bigger.**
    // Nobody presses a tool's own icon to be told they already have it, and
    // there is nothing else it could sensibly mean — the tool is on screen, so
    // the only thing left to ask for is the whole window. Which panel is being
    // worked in has nothing to do with it: the answer is about the tool, not
    // about where the keyboard happens to be.
    //
    // Only where no panel was named. The location menu names one, and naming
    // one is asking for that panel rather than for the window.
    if (panel == null && surfaces.contains(PluginSurface.fullscreen)) {
      final holding = _panelHolding(view);
      if (holding != null) {
        await toFullScreen(context, holding);
        return;
      }
    }

    final target = panel ??
        (surfaces.contains(PluginSurface.fullscreen) ? null : app.active);

    if (target != null && view.spec.isPanelCapable) {
      await _attach(context, view, target);
      return;
    }

    // A view is one page, not a stack of them. Asking for it again while it is
    // already up is how the same icon gets pressed twice — and the answer is
    // not silence: **the page is brought back**.
    //
    // Item 51: system information, then the disk map, then system
    // information again, and the third press did nothing at all. The first
    // page was still there, underneath the second, so the claim was honest —
    // what was wrong was refusing without saying so and without going to it.
    if (!app.claimPage(view.id)) {
      final name = AppState.pageRouteName(view.id);
      Navigator.of(context).popUntil((route) =>
          route.settings.name == name || route.isFirst);
      return;
    }

    // Where the view was looking while it filled the window. Kept because the
    // move into a panel has to put it somewhere — see below.
    final wasLooking = app.active.location;
    bool toPanel;
    try {
      toPanel = await PluginViewPage.open(
        context,
        view: view,
        location: app.active.location,
        // Full screen there is no panel beside the view, so "the other one" is
        // the panel that was not being worked in — the same answer the host
        // gives a full-screen view's actions.
        otherLocation: app.inactive.location,
        onActions: (actions) => apply(context, actions, null, from: view),
        // Only where there is somewhere to go. A view that declares only the
        // full screen has no panel form, and a button that says otherwise is
        // a button that lies.
        canToPanel:
            view.spec.isPanelCapable && surfaces.contains(PluginSurface.panel),
      );
    } finally {
      app.releasePage(view.id);
    }

    // Left by asking for the panel rather than by going back. The page has
    // already gone and the claim is already released, which is why this is
    // out here and not in a callback.
    if (toPanel && context.mounted) {
      await _sendTheOtherPanel(view, wasLooking);
      if (!context.mounted) return;
      await _attach(context, view, app.active);
      return;
    }
    onReturn?.call();
  }

  /// Sends a panel where an action pointed, whether that is a place or a
  /// thing.
  ///
  /// **A file is a place too.** "Show me this file" is what a tool means when
  /// it hands over the path of one — the git tool pointing at a file as it was
  /// at a commit, so it can be read, compared or copied out — and the answer
  /// is the folder it lives in with the cursor standing on it. Sending the
  /// panel *at* the file would ask a provider to list a thing that has no
  /// contents, and it would fail for the most useful case there is.
  ///
  /// **The tool says where, and which row it meant.** A panel can only be sent
  /// somewhere that lists, so pointing at a file is a folder plus a name — and
  /// the name comes from whoever pointed, because they know. Working it out
  /// here would mean asking a provider what kind of thing it is, which for a
  /// plugin's own file system is a round trip to another process to learn what
  /// that process already knew.
  Future<void> _sendPanelTo(
    HostAction action,
    PanelController? origin,
    VfsPath path,
    RegisteredView? from,
  ) async {
    final target = panelFor(action.target, origin);

    // What the panel beside it is showing, read *before* anything moves. Half
    // of the way back is putting that panel back too — see [WayBack] — and
    // once the tool has closed there is nobody left who remembers.
    final beside = identical(target, app.left) ? app.right : app.left;
    final was = target.location;
    final besideWas = beside.location;

    final moved = await target.navigateTo(path, cursorOn: action.name);

    // A tool that sends its own panel somewhere is a tool that has just closed
    // itself. Only then is there a journey to come back from: sending the
    // *other* panel leaves this one exactly where it was.
    final wasItsOwn = identical(target, origin) ||
        (origin == null && action.target == ActionTarget.self);
    if (!moved || !wasItsOwn || from == null || was == null) return;

    target.rememberWayBack(WayBack(
      label: action.back?.isNotEmpty == true
          ? action.back!
          : tr('Back to {tool}', {'tool': from.spec.title}),
      viewId: from.id,
      to: was,
      into: path,
      beside: besideWas,
    ));
  }

  /// Undoes the journey a tool sent this panel on: both panels back where they
  /// were, and the tool open again.
  ///
  /// **The other panel goes first.** A view that follows something reads the
  /// panel beside it as it opens, so putting this one back and starting the
  /// tool before the other has moved would hand the tool whatever folder
  /// happened to be there: a different repository, or none at all.
  Future<void> takeTheWayBack(
    BuildContext context,
    PanelController panel,
  ) async {
    final back = panel.wayBack;
    if (back == null) return;

    // **A context that outlives the control that was pressed.** The way back
    // is drawn in the panel's path bar and goes the instant the panel moves,
    // so by the time the tool could be opened again the button's own context
    // is unmounted — and the tool silently did not come back. The navigator
    // sits above both panels and is still there.
    final stable = Navigator.maybeOf(context)?.context ?? context;
    panel.forgetWayBack();

    final other = identical(panel, app.left) ? app.right : app.left;
    final beside = back.beside;
    if (beside != null && other.location != beside && !other.isAttached) {
      await other.navigateTo(beside);
    }
    await panel.navigateTo(back.to);

    final view = app.plugins.view(back.viewId);
    if (view == null || !stable.mounted) return;
    await open(stable, view, panel: panel);
  }

  /// Whichever panel is holding [view], or null when neither is.
  PanelController? _panelHolding(RegisteredView view) {
    for (final panel in [app.left, app.right]) {
      final held = panel.attachment;
      if (held is PluginViewAttachment && held.view.id == view.id) return panel;
    }
    return null;
  }

  /// Points the panel beside the view at what the view was looking at.
  ///
  /// **A view that follows a panel needs that panel to be somewhere.** Full
  /// screen it was looking at the folder the window was opened on; put into a
  /// panel it looks at the *other* panel instead, and if that panel is
  /// somewhere else the view arrives showing something the user never asked
  /// for — a git tool that filled the window with one repository, moved into a
  /// panel, and said the folder beside it is not a repository at all.
  ///
  /// So: git on the left, and the right stands in git's own folder. Walk that
  /// panel somewhere else and the tool follows it, which is the whole of what
  /// `follows` means and is now true from the first frame rather than from the
  /// first navigation.
  ///
  /// Only for a view that follows something. Moving a panel under a view that
  /// never reads it would be moving the user's folder for no reason at all.
  Future<void> _sendTheOtherPanel(RegisteredView view, VfsPath? to) async {
    if (view.spec.follows == ViewFollows.none || to == null) return;
    final other = app.inactive;
    if (other.location == to) return;
    await other.navigateTo(to);
  }

  /// The other half of the switch: a view in a panel, put on the whole window.
  ///
  /// The panel gives the view up first. Two copies of one view running at once
  /// is what the page claim exists to prevent, and a view that keeps a
  /// connection or a scan would have two of those as well.
  Future<void> toFullScreen(BuildContext context, PanelController panel) async {
    final held = panel.attachment;
    if (held is! PluginViewAttachment) return;
    final view = held.view;
    if (!app.plugins.surfacesForView(view).contains(PluginSurface.fullscreen)) {
      return;
    }

    await panel.detach();
    if (!context.mounted) return;
    await open(context, view);
  }

  Future<void> _attach(
    BuildContext context,
    RegisteredView view,
    PanelController target,
  ) async {
    // Already here. Handing the panel the same view again would throw away
    // whatever it had built — a measured disk, say — and start it over.
    final held = target.attachment;
    if (held is PluginViewAttachment && held.view.id == view.id) {
      app.activate(target);
      return;
    }

    // What a view that follows something follows: the panel that is *not*
    // holding it. That is what makes one side a viewport onto the other.
    final source = identical(target, app.left) ? app.right : app.left;

    // **The same view in the other panel moves here rather than doubling.**
    // A view is one thing — that is what the page claim says of the full
    // screen, and a panel is no different. Two copies of a tool that follows
    // the other panel is the worse case rather than merely the wasteful one:
    // each would be following the other, so neither would be looking at a
    // folder, and both would say there is nothing there.
    //
    // Asked for on the right while it is on the left, it goes right — and the
    // panel it leaves goes back to its own listing, which is exactly the
    // folder the view then reads.
    final elsewhere = source.attachment;
    if (elsewhere is PluginViewAttachment && elsewhere.view.id == view.id) {
      await source.detach();
    }

    final attachment = PluginViewAttachment(
      view: view,
      session: target.isLeft ? 'left' : 'right',
      location: target.location,
      // The panel that is not holding it, which is the same panel a view that
      // follows something follows.
      otherLocation: source.location,
      onActions: (actions) => apply(context, actions, target, from: view),
    );
    await target.attach(attachment);
    app.activate(target);
    await attachment.start(
      location: source.location,
      cursor: source.cursorEntry,
    );
  }

  /// Ctrl+Q: the panel that is not being worked in becomes a viewport onto the
  /// cursor in the one that is.
  ///
  /// Total Commander's binding and its behaviour. It needs no plugin of its
  /// own — it resolves whatever viewer F3 would, so every viewer ever written
  /// works here on the day this ships.
  Future<void> toggleQuickView() async {
    final target = app.inactive;
    if (target.isAttached) {
      await target.detach();
      return;
    }

    final source = app.active;
    final attachment = QuickViewAttachment(plugins: app.plugins);
    await target.attach(attachment);
    attachment.follow(location: source.location, cursor: source.cursorEntry);
  }

  /// Carries out what a view asked for, and answers with what came of it.
  ///
  /// [origin] is the panel the view is in, or null for a full-screen one, and
  /// that is what decides what "the other panel" means. A view says what it
  /// wants; where it lands is the host's business.
  Future<ViewOutcome> apply(
    BuildContext context,
    List<HostAction> actions,
    PanelController? origin, {
    RegisteredView? from,
  }) async {
    final deleted = <VfsPath>[];
    final answers = <String, bool>{};
    for (final action in actions) {
      switch (action.kind) {
        case HostActionKind.navigate:
          final path = action.path;
          if (path != null) await _sendPanelTo(action, origin, path, from);

        case HostActionKind.view:
          final path = action.path;
          if (path != null && context.mounted) await _openViewer(context, path);

        case HostActionKind.notice:
          final message = action.message;
          if (message != null && context.mounted) showNotice(context, message);

        case HostActionKind.refresh:
          await panelFor(action.target, origin).refresh();

        case HostActionKind.ask:
          final id = action.id;
          if (id != null && id.isNotEmpty && context.mounted) {
            answers[id] = await confirm(
              context,
              title: action.title ?? id,
              message: action.message ?? '',
              confirmLabel: action.confirmLabel ?? tr('Yes'),
              destructive: action.danger,
            );
          }

        case HostActionKind.delete:
          if (context.mounted) {
            deleted.addAll(await _delete(context, action.paths));
          }

        case HostActionKind.close:
          if (origin != null) {
            await origin.detach();
          } else if (context.mounted) {
            await Navigator.of(context).maybePop();
          }

        // Both are the attachment's own: it holds the content, so it is the
        // one that can keep a page and put it back. They reach here only
        // because every action passes through, and doing anything with them
        // twice is what would go wrong.
        case HostActionKind.page:
        case HostActionKind.back:
          break;

        case HostActionKind.fullscreen:
          // Only from a panel: full screen there is no bigger to get. The
          // panel gives the view up and it opens again on the whole window,
          // which is the same road the user's own key takes.
          if (origin != null && context.mounted) {
            await toFullScreen(context, origin);
          }

        // A view written against a newer app, asking for something this one
        // has never heard of. Ignored rather than refused, so the rest of what
        // it asked for still happens.
        case HostActionKind.unknown:
          break;
      }
    }
    return ViewOutcome(deleted: deleted, answers: answers);
  }

  /// Deletes what a view asked to be rid of, the way F8 would.
  ///
  /// Deliberately not a plugin's own job. The user is asked first, in the
  /// application's own words; the recycle bin is used wherever it exists; and
  /// what comes back is what actually went, so a view that was told no can
  /// draw the truth rather than what it hoped for.
  Future<List<VfsPath>> _delete(
    BuildContext context,
    List<VfsPath> paths,
  ) async {
    if (paths.isEmpty) return const [];

    final canTrash = app.operations.canTrash(paths);
    // **The word has to be typed.** Deleting from a view is too easy
    // otherwise: a view asks for this with a list the user did not pick row by
    // row — everything under a wedge, every copy of a file bar one — so the
    // press that agrees is a press about things nobody has looked at one at a
    // time. F8 is left as it was: there the hand chose what it is about.
    final agreed = await confirmByTyping(
      context,
      title: canTrash
          ? tr('Move {count} item(s) to the recycle bin', {
              'count': paths.length,
            })
          : tr('Permanently delete {count} item(s)', {'count': paths.length}),
      message: paths.length == 1
          ? paths.first.display
          : canTrash
          ? tr('They can be restored from the recycle bin.')
          : tr('This cannot be undone.'),
      word: tr('yes'),
      confirmLabel: canTrash ? tr('Move to bin') : tr('Delete'),
    );
    if (!agreed || !context.mounted) return const [];

    final result = await runWithProgress(
      context,
      title: canTrash ? tr('Moving to the recycle bin…') : tr('Deleting…'),
      task: (onProgress, token) => app.operations.delete(
        paths,
        toTrash: canTrash,
        onProgress: onProgress,
        token: token,
      ),
    );

    if (context.mounted) showOperationResult(context, result);

    // The result counts what worked; it does not say which. When some of it
    // failed, the only honest answer is to go and look.
    final gone = result.hasErrors || result.cancelled
        ? await _stillMissing(paths)
        : paths;

    await Future.wait([app.left.refresh(), app.right.refresh()]);
    return gone;
  }

  Future<List<VfsPath>> _stillMissing(List<VfsPath> paths) async {
    final gone = <VfsPath>[];
    for (final path in paths) {
      try {
        if (await app.fileSystems.resolve(path).stat(path) == null) {
          gone.add(path);
        }
      } on Object {
        // Unreachable now says nothing about whether it was deleted, so the
        // safe answer is to leave it on the map.
      }
    }
    return gone;
  }

  PanelController panelFor(ActionTarget target, PanelController? origin) =>
      switch (target) {
        ActionTarget.left => app.left,
        ActionTarget.right => app.right,
        ActionTarget.self => origin ?? app.active,
        // "The other panel" means the one beside the view — but a full-screen
        // view has nothing beside it, so there is nothing for "other" to
        // contrast with. It means the panel you came from and will come back
        // to, which is the active one. Sending it to the *inactive* panel put
        // the answer where the user was not looking: the map appeared to have
        // stopped walking the panel along at all, because the panel it walked
        // was hidden behind the map and behind the one being watched.
        ActionTarget.other => origin == null
            ? app.active
            : (identical(origin, app.left) ? app.right : app.left),
      };

  /// Opens the viewer on a location a view named, rather than on a row of a
  /// listing — a view knows a URL, not an entry, so the entry is looked up.
  Future<void> _openViewer(BuildContext context, VfsPath path) async {
    final entry = await app.fileSystems.resolve(path).stat(path);
    if (entry == null || !context.mounted) return;

    final candidates = await app.plugins.viewersForFile(entry);
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      showNotice(
        context,
        tr('No viewer plugin handles {what}.', {
          'what': entry.extension.isEmpty
              ? tr('this file type')
              : '.${entry.extension}',
        }),
        long: true,
      );
      return;
    }

    await Navigator.of(context).push(
      MotionPageRoute<void>.of(
        context,
        builder: (_) => PluginViewerPage(entry: entry, viewers: candidates),
      ),
    );
  }
}
