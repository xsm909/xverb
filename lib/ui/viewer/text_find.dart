import 'package:flutter/material.dart';

/// Finding something in the text a viewer is showing, and marking it.
///
/// **Over whatever it was already drawn as.** A file may be plain, coloured by
/// a grammar, or a diff in its own two colours, and a search that only worked
/// on one of those would be a search you have to think about. So nothing here
/// knows what the text is: it takes the spans somebody else built and puts a
/// mark *through* them, keeping every colour and weight underneath.

/// Where [query] occurs in [body], as `(start, end)` in characters.
///
/// Case is ignored, because a reader looking for `TODO` means `todo` as well
/// and the one time they do not, they can see which is which on the page.
/// Overlaps are not: after a match the search goes on from its end, so `aa` in
/// `aaa` is one match and not two.
List<(int, int)> findAll(String body, String query) {
  if (query.isEmpty || body.isEmpty) return const [];
  final haystack = body.toLowerCase();
  final needle = query.toLowerCase();

  final found = <(int, int)>[];
  var at = haystack.indexOf(needle);
  while (at >= 0) {
    found.add((at, at + needle.length));
    at = haystack.indexOf(needle, at + needle.length);
  }
  return found;
}

/// [tree] with every range in [matches] marked.
///
/// The spans are split where a match begins and ends, so a match that runs
/// across a keyword and the bracket after it is still one mark. [current] is
/// the one being looked at, drawn differently from the rest — a search that
/// marks twenty things and cannot say which one you are on is a search that
/// makes you count.
///
/// The text is never changed, only cut: joining the result back together
/// returns the file, which is the same rule the highlighters follow.
TextSpan markMatches(
  TextSpan tree,
  List<(int, int)> matches, {
  required int current,
  required Color found,
  required Color here,
}) {
  if (matches.isEmpty) return tree;

  final marked = <InlineSpan>[];
  var offset = 0;
  var next = 0;

  void walk(InlineSpan span) {
    if (span is! TextSpan) {
      marked.add(span);
      return;
    }
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      var at = 0;
      while (at < text.length) {
        // Matches are in order, so the search for the one that touches this
        // span starts where the last one left off rather than at the front.
        while (next < matches.length && matches[next].$2 <= offset + at) {
          next++;
        }
        if (next >= matches.length) break;

        final (start, end) = matches[next];
        final from = (start - offset).clamp(0, text.length);
        final to = (end - offset).clamp(0, text.length);
        if (from >= text.length) break;

        if (from > at) {
          marked.add(TextSpan(text: text.substring(at, from), style: span.style));
        }
        marked.add(TextSpan(
          text: text.substring(from, to),
          style: (span.style ?? const TextStyle()).copyWith(
            backgroundColor: next == current ? here : found,
          ),
        ));
        at = to;
        if (to >= text.length) break;
      }
      if (at < text.length) {
        marked.add(TextSpan(text: text.substring(at), style: span.style));
      }
      offset += text.length;
    }

    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child);
    }
  }

  walk(tree);
  return TextSpan(style: tree.style, children: marked);
}

/// Everything drawn, joined back into the string it came from.
///
/// Only a test wants this, and the test is the one that matters: a mark that
/// quietly drops a character would be a viewer lying about a file.
String textOfSpans(InlineSpan span) {
  final out = StringBuffer();
  void walk(InlineSpan at) {
    if (at is TextSpan) {
      out.write(at.text ?? '');
      for (final child in at.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return out.toString();
}
