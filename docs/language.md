# Language

The application ships in **English, Russian, Spanish, German, French, Korean
and Japanese**, and English is the fallback whenever anything is missing.
Settings → Appearance → Language switches it; **System** follows the machine and
falls back to English when the machine's language is not one of the seven.

A language is **not a plugin**. It travels in the app bundle, so the interface
is readable on a machine with nothing installed — including the first launch and
the platforms where plugins cannot run at all.

## The key is the English text

```dart
Text(tr('Delete permanently'))
```

```json
{ "Delete permanently": "Удалить безвозвратно" }
```

There is no `menu.file.delete.confirm`. The English sentence is the key, which
buys three things:

- **English needs no catalogue.** The source already is one, so it cannot fall
  out of step with itself.
- **A missing translation degrades to English by construction**, not by a rule
  someone has to remember to follow.
- **A translator is handed sentences**, not identifiers that say nothing about
  how the result reads.

The cost is real and worth knowing: changing an English string orphans its
translations, which then quietly fall back to English until someone catches up.
That is the same bargain gettext and Qt's `tr()` make, and the alternative is a
second name for every sentence in the application, kept in step by hand.

## Placeholders

Named, in braces, filled at the call:

```dart
tr('Delete {count} items?', {'count': targets.length})
```

Named rather than positional because a translation reorders the sentence around
them, and `%s` cannot survive that. A translation may leave one out — a sentence
can be rephrased so it is not needed — but one it *invents* would reach the user
as literal braces, so the tests check for that.

## A catalogue is decoded in the app, not by the bundle

`Localisation.fromAsset` reads the bytes and decodes them itself rather than calling
`rootBundle.loadString`, which hands anything over **50 KB** to an isolate. An isolate never
finishes inside a widget test, whose clock is fake: the Russian catalogue crossed that line on
1.0.0.317 and hung `language_change_test`, while Japanese — still under it — went on passing,
which is what made it look like a Russian bug rather than a size one. Decoding fifty kilobytes
takes well under a millisecond and happens once per change of language, so the isolate was
never buying anything here. `i18n_test` loads every shipped catalogue through `fromAsset`, so
the next one to grow past the line says so.

## A missing translation is a failing test

`translation_coverage_test` reads the sources and asks every shipped catalogue whether it
covers them. It sees two things: every `tr('…')` whose argument is a literal — adjacent
literals joined the way Dart joins them — and the settings rows, whose label and note are
written as English literals on purpose so the settings search can match both, and which go
through `tr()` where they are drawn.

It cannot see a key that arrives in a variable — `tr(entry.key)`, About's table of bindings,
anything a plugin supplies. **Passing is therefore not proof of a complete catalogue; failing
is proof of a hole.**

It was written on 2026-09-06, after two settings rows built since the sweep of 1.0.0.317 were
found to have been English in every language since the day they were added. A new sentence in
the interface now breaks this test until the six catalogues have it, which is the point: the
cheapest moment to write a translation is the moment the English is written.

## Adding a language

1. Add a `LanguageOption` to `LanguageOption.shipped` in
   `lib/core/i18n/i18n.dart`, named in English **and in itself** — someone
   looking for their own language scans for the word they would write.
2. Drop `assets/i18n/<code>.json` beside the others: English on the left,
   the translation on the right. Anything absent stays English.
3. If the ordinary interface font cannot draw it, set `needsWideCoverage`. That
   is what puts a fallback stack of system faces under the theme; without it
   Japanese comes out as rows of boxes. **The stack has to name a face for that
   script**: the Japanese families a system ships carry no Hangul and the Korean
   ones no kana, so `_wideCoverageFonts` in `lib/app.dart` lists both, and a
   third script would need its own entries there.

Nothing else. The list in Settings is built from `shipped`, and the catalogue is
read at startup and again whenever the language changes.

## What is not translated

- **Menu search keywords.** A menu row is found by its own label, which *is*
  translated; the extra English keywords behind it are an alias, not a label.
- **Example text that is not prose** — a path like `C:\Users`, a mask like
  `*.dart *.yaml`, a URL. Translating those would make them wrong.
- **Plugin strings**, for now. A plugin's title, description and field labels
  come from its manifest and are shown as written. Passing them through the same
  lookup is the obvious next step, and it is what would let a language cover the
  collection as well as the app.

## Two traps worth naming

**A page already on screen is not rebuilt because an ancestor was.** A pushed
route rebuilds only when something it watches changes. The settings page — which
is exactly where the language is switched — kept the language it was first drawn
in until it was made to watch the settings store.

**Watching is not enough on its own.** Flutter skips a subtree whose widget has
not changed, and a `const` child is the same instance on every rebuild. The
settings tabs are `const`, so Appearance updated (it watches the store itself)
while Plugins and About kept the old language until the page was closed and
opened again. The language is part of the settings page's key now, so the whole
subtree is rebuilt — including tabs added later that nobody remembers to make
listen. Anything long-lived holding `const` children that show text needs the
same treatment.
