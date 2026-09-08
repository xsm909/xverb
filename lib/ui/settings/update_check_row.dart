import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/update/release_check.dart';
import '../../core/update/update_installer.dart';
import '../../core/update/update_log.dart';
import '../../core/update/update_start.dart';
import '../../core/version.dart';
import '../motion.dart';
import '../notice.dart';

/// Asks the release repository whether anything newer was published.
///
/// Only when pressed. Opening a settings tab is not a reason to reach the
/// network, and a check that happens by itself is a check nobody asked for.
///
/// It downloads nothing and changes nothing. When there is something newer it
/// says so and gives the one line that installs it — which is the whole of the
/// update path that exists today, and saying "there is an update" without
/// saying how to get it would be worse than not asking.
class UpdateCheckRow extends StatefulWidget {
  const UpdateCheckRow({
    super.key,
    this.source,
    this.installedAt,
    this.handOver,
  });

  /// Left null in the application. A test hands in a directory standing in for
  /// the repository, which is how this is exercised without a network.
  final ReleaseSource? source;

  /// The installed copy to replace. Null in the application, where it is the
  /// folder this one is running from; a test passes a folder of its own.
  final Directory? installedAt;

  /// What to do once the update is staged. Null in the application, where the
  /// other copy is started and this one closes.
  final Future<void> Function(PreparedUpdate)? handOver;

  @override
  State<UpdateCheckRow> createState() => UpdateCheckRowState();
}

@visibleForTesting
class UpdateCheckRowState extends State<UpdateCheckRow> {
  bool _checking = false;
  UpdateCheckResult? _result;
  StageStep? _staging;
  Object? _stagingProblem;
  List<String> _notes = const [];


  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final result = await checkForUpdate(
      source: widget.source ?? defaultReleaseSource(),
      running: ReleaseVersion.tryParse(kAppVersion) ?? const ReleaseVersion([0, 0, 0, 0]),
    );
    // The check outlives the tab if somebody closes settings while it is in
    // flight, and setState on a dead widget is an error rather than a no-op.
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      _notes = const [];
    });

    // Read only when there is something to offer: a release nobody is being
    // shown has nothing worth saying, and a check must stay one request.
    if (result is! UpdateAvailable) return;
    final notes = await ReleaseNotes.fetch(
        widget.source ?? defaultReleaseSource(), result.archive.version);
    if (!mounted) return;
    setState(() => _notes = notes);
  }

  /// Takes the update: staged here, where there is a window to show it in,
  /// then handed to the copy that performs the swap. See [UpdateStart].
  Future<void> _install(ReleaseArchive archive) async {
    setState(() {
      _staging = StageStep.downloading;
      _stagingProblem = null;
    });
    try {
      await UpdateStart.run(
        source: widget.source ?? defaultReleaseSource(),
        archive: archive,
        installedAt: widget.installedAt,
        handOver: widget.handOver,
        onStep: (step) {
          if (mounted) setState(() => _staging = step);
        },
      );
    } on Object catch (problem) {
      if (!mounted) return;
      setState(() {
        _staging = null;
        _stagingProblem = problem;
      });
    }
  }

  /// The failure, with what it was about, onto the desktop's clipboard.
  Future<void> _copyProblem() async {
    final where = await UpdateLog.path();
    await Clipboard.setData(ClipboardData(
      text: [
        'xverb $kAppVersion \u00b7 ${Platform.operatingSystem} '
            '${Platform.operatingSystemVersion}',
        '$_stagingProblem',
        ?where,
      ].join('\n'),
    ));
    if (mounted) showNotice(context, tr('Copied to the clipboard.'));
  }

  String _stagingNote(StageStep step) => switch (step) {
        StageStep.downloading => tr('Downloading…'),
        StageStep.verifying => tr('Checking what was downloaded…'),
        StageStep.unpacking => tr('Unpacking…'),
        StageStep.copying => tr('Preparing to restart…'),
        StageStep.ready => tr('Restarting…'),
      };

  /// The line that installs the newest release, for the machine this is.
  static String get _installLine {
    const base = 'https://raw.githubusercontent.com/xsm909/xverb-release/main';
    return switch (currentPlatformName()) {
      'windows' => 'irm $base/install.ps1 | iex',
      _ => 'curl -fsSL $base/install.sh | sh',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _checking ? null : _check,
            child: Text(_checking
                ? tr('Checking for updates…')
                : tr('Check for updates')),
          ),
        ),
        AnimatedSize(
          duration: motionOf(context, kSettingsFoldDuration),
          curve: kBothCurve,
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: motionOf(context, kSettingsFoldDuration),
            child: _answer(theme),
          ),
        ),
      ],
    );
  }

  Widget _answer(ThemeData theme) {
    final result = _result;
    if (result == null || _checking) return const SizedBox.shrink();
    final small = theme.textTheme.bodySmall;
    return switch (result) {
      UpToDate() => Text(
          tr('This is the newest release.'),
          key: const ValueKey('up-to-date'),
          style: small,
        ),
      NoReleasePublished(:final source) => Text(
          tr('Nothing has been published yet at {source}.', {'source': source}),
          key: const ValueKey('none'),
          style: small,
        ),
      // Told apart from "nothing published" on purpose: a repository that
      // cannot be reached and a repository holding no release call for
      // different things from whoever is reading this.
      CheckFailed(:final problem) => Text(
          tr('Could not read the release listing: {problem}',
              {'problem': '$problem'}),
          key: const ValueKey('failed'),
          style: small?.copyWith(color: theme.colorScheme.error),
        ),
      UpdateAvailable(:final archive) => Column(
          key: const ValueKey('available'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('{version} is available.', {'version': '${archive.version}'}),
              style: small?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
            if (_notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tr('What is new'),
                  style: small?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              for (final line in _notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text('\u2022 $line', style: small),
                ),
            ],
            const SizedBox(height: 4),
            Text(tr('Install it with:'), style: small),
            const SizedBox(height: 2),
            SelectableText(
              _installLine,
              style: small?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            if (_staging != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(_stagingNote(_staging!), style: small),
                ],
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: () => _install(archive),
                  child: Text(tr('Install and restart')),
                ),
              ),
            // Selectable, and with the whole of it one press from the
            // clipboard. It stays on the row until something else is asked —
            // which is the point: a reason an update did not happen is the
            // input to whatever a person does next about it.
            if (_stagingProblem != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                '$_stagingProblem',
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => unawaited(_copyProblem()),
                  child: Text(tr('Copy')),
                ),
              ),
            ],
          ],
        ),
    };
  }
}
