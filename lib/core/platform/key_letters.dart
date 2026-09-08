import 'package:flutter/services.dart';

/// The letter a key stands for when the keyboard's layout is not being asked.
///
/// A binding is about the key under the finger, not about the character that key
/// happens to produce today. With a non-Latin layout in force the key marked
/// `F` composes a letter of that alphabet, and Flutter reports that as the
/// logical key — so Alt+F stopped
/// opening File and `C` stopped picking the C: drive the moment the layout was
/// switched, which is exactly what a file manager must not do.
///
/// The physical key survives the layout: it is the position on the board, sent
/// as a USB HID usage whatever the OS thinks is printed on it. These are the
/// usages for the letter and digit rows, which is all a binding ever needs —
/// everything else (the function row, the arrows) is already layout-independent
/// because it has no character to compose.
///
/// Lower case, because every accelerator in the application is matched lower
/// case and a comparison that has to remember to fold the case is a comparison
/// somebody will forget to fold.
/// The letter a key stands for when it is read as a **binding** rather than as
/// typing — Alt+F for File, `C` for the C: drive.
///
/// A binding is about the key under the finger. With a non-Latin layout the key
/// marked `F` reports a letter of that alphabet, and asking the layout what it
/// composed took every Alt binding away the moment the language changed; the
/// position on the board is the same key whatever is printed on it. Alt+F1 then
/// C picks drive C in any layout.
///
/// **The layout is still asked first**, so a board that really does put a letter
/// somewhere else keeps it.
///
/// Held here rather than on the screen because a menu that is already open is a
/// *route*, and it has to read a key the same way the screen under it would —
/// see item 82. One rule, one place.
String? bindingLetter(KeyEvent event) {
  final label = event.logicalKey.keyLabel;
  if (label.length == 1 && _letterOrDigit.hasMatch(label)) {
    return label.toLowerCase();
  }
  return layoutIndependentLetter(event.physicalKey);
}

final RegExp _letterOrDigit = RegExp(r'[A-Za-z0-9]');

String? layoutIndependentLetter(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= _keyA && usage <= _keyZ) {
    return String.fromCharCode(_a + usage - _keyA);
  }
  // `1` through `9` run together and `0` sits after them rather than before,
  // which is the one place this table is not simply arithmetic.
  if (usage >= _digit1 && usage <= _digit9) {
    return String.fromCharCode(_one + usage - _digit1);
  }
  if (usage == _digit0) return '0';
  return null;
}

const int _keyA = 0x00070004;
const int _keyZ = 0x0007001d;
const int _digit1 = 0x0007001e;
const int _digit9 = 0x00070026;
const int _digit0 = 0x00070027;

final int _a = 'a'.codeUnitAt(0);
final int _one = '1'.codeUnitAt(0);
