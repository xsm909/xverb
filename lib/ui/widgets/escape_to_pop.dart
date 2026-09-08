import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes Escape close a pushed page.
///
/// Dialogs get this from the framework, but `MaterialPageRoute` does not, so
/// full-screen pages such as the viewer and the settings need it spelled out.
class EscapeToPop extends StatelessWidget {
  const EscapeToPop({super.key, required this.child, this.onEscape});

  final Widget child;

  /// What the key means on this page, when it is not simply "close it". A page
  /// that has something of its own open — a view with a page pushed over its
  /// first one — answers Escape with *that* first, and pops when it returns
  /// false. Null is the plain behaviour every other page wants.
  final bool Function()? onEscape;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      // A handler rather than a Shortcuts binding: text fields inside the page
      // must keep every other key, and this only ever claims Escape.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        if (onEscape?.call() ?? false) return KeyEventResult.handled;
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
