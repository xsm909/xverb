import 'package:flutter/widgets.dart';

/// Whether the keyboard is inside a text field somebody else owns.
///
/// **A field does not take its characters as key events.** What is typed
/// reaches an [EditableText] through the platform's input connection, and the
/// key event itself goes on up the tree unclaimed — so a handler high above the
/// field sees every letter of what is being typed into it and, if it claims
/// them, does the same thing twice. That is exactly what happened to the commit
/// message: every letter went into the field *and* into the command line.
///
/// Asked of the focus tree rather than tracked, because there is no one place
/// where a field gets the keyboard: a plugin's form, a rename box, anything a
/// page puts on screen. What is true is true of all of them.
bool keyboardIsInAField() {
  final focus = FocusManager.instance.primaryFocus;
  final where = focus?.context;
  if (where == null) return false;
  // The node an [EditableText] focuses is one it builds itself, so the field is
  // above it rather than at it.
  return where.widget is EditableText ||
      where.findAncestorWidgetOfExactType<EditableText>() != null;
}
