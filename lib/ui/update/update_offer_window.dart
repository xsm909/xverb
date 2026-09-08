/// The window that asks whether to take an update.
///
/// An update is offered, never taken. Three answers, and none of them is a
/// trick: install it, be asked again tomorrow, or stay on what is running.
/// The window says what the release changed before it asks, because "there is
/// a new version" is not information anybody can answer.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/update/release_check.dart';
import '../../state/app_state.dart';
import '../../state/window_stack.dart';
import '../windows/window_dialogs.dart';

enum UpdateAnswer { install, later, staying }

/// The window itself, apart from the opening of it.
///
/// Kept separate so a test can put it on a stack of its own rather than
/// needing a whole application behind it — the same shape the other window
/// tests here use.
///
/// Escape and the close button answer [UpdateAnswer.later]: dismissing a
/// window is not a decision to stay behind for ever, and reading it as one
/// would silence a release nobody ever read about.
DeskWindow updateOfferWindow({
  required ReleaseVersion running,
  required ReleaseVersion offered,
  required List<String> notes,
}) {
  late final DeskWindow window;
  window = DeskWindow(
    id: 'update-offer',
    title: tr('Version {version} is out', {'version': '$offered'}),
    icon: Icons.system_update_alt,
    modal: true,
    // Room for five lines and three buttons, and the buttons wrap in a
    // language whose words are longer than English's — which is most of them.
    preferredSize: const Size(620, 420),
    minSize: const Size(420, 300),
    builder: (_) => WindowForm(
      onSubmit: () => window.close(UpdateAnswer.install),
      actions: [
        TextButton(
          onPressed: () => window.close(UpdateAnswer.staying),
          child: Text(tr('Stay on {version}', {'version': '$running'})),
        ),
        TextButton(
          onPressed: () => window.close(UpdateAnswer.later),
          child: Text(tr('Remind me tomorrow')),
        ),
        FilledButton(
          onPressed: () => window.close(UpdateAnswer.install),
          child: Text(tr('Install and restart')),
        ),
      ],
      child: _WhatIsNew(notes: notes, running: running),
    ),
  );
  return window;
}

/// Asks, and never answers for the person: anything but the three buttons —
/// Escape, the close button, a window closed from elsewhere — is *later*.
Future<UpdateAnswer> showUpdateOffer(
  BuildContext context, {
  required ReleaseVersion running,
  required ReleaseVersion offered,
  required List<String> notes,
}) async {
  final windows = context.read<AppState>().windows;
  final answer = await windows.open(updateOfferWindow(
    running: running,
    offered: offered,
    notes: notes,
  ));
  return answer is UpdateAnswer ? answer : UpdateAnswer.later;
}

class _WhatIsNew extends StatelessWidget {
  const _WhatIsNew({required this.notes, required this.running});

  final List<String> notes;
  final ReleaseVersion running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(
          tr('You are running {version}.', {'version': '$running'}),
          style: small?.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 10),
        if (notes.isEmpty)
          // Said plainly rather than left blank. A release published without
          // notes is still a release, and an empty space where the reason
          // should be reads as something having gone wrong.
          Text(tr('This release came without notes.'), style: small)
        else ...[
          Text(
            tr('What is new'),
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final line in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ', style: small),
                  Expanded(child: Text(line, style: small)),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
