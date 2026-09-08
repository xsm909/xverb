# Searching for files

`Alt+F7`, or **Commands → Find files…**. The search opens as an internal
window, modeless on purpose: a walk of a large tree takes a while and the
panels stay usable while it runs.

## What it takes

- **Search for** — a file mask. `*.dart *.yaml` are alternatives, `|` starts
  the exclusions (`*.dart | *.g.dart`), and a word with no wildcard in it is
  matched as a substring, so typing `readme` finds `README.md`.
- **Containing text** — optional. Leaving it empty is the difference between a
  search that takes a second and one that reads every file it matched.
- Subdirectories, case sensitivity, whole words.

The starting folder comes from the active panel. It does not follow the panel
afterwards — a search that silently changed its own scope while running would
be worse than one that needs a button pressed.

## Feeding results to a panel

This is the part that makes a search worth having in a file manager, and it is
Total Commander's "feed to listbox": **Feed to panel** fills the active panel
with the results. They are ordinary rows — copy, move, view, delete and mark
all work on them — except that each one carries its own full path, so a single
listing can hold files from all over the disk. The status line shows which
folder the row under the cursor actually lives in.

The panel is then in a *virtual* listing (`PanelController.isVirtual`). `..`
leaves the result set and returns to the folder the search started from;
so does the button in the path bar. Refreshing a result set deliberately does
nothing, because re-reading a directory would throw the results away.

## How the engine walks

`lib/core/search/file_search.dart` is a stream of events — hits, progress, and
failures — over the `FileSystemProvider` abstraction, which means a search runs
against FTP or any other plugin transport exactly as it does against a disk.

- **Breadth-first**, so shallow results (the ones usually wanted) arrive first.
- **Unreadable directories are events, not exceptions.** Half of `C:\` cannot
  be listed; a search that stopped at the first denial would be useless.
- **A result cap** (20 000) stops a search of an entire drive from growing
  until it takes the app with it. The window says when the cap was hit.
- **Text matching reads in chunks** and carries the tail of each one over, so a
  match straddling a chunk boundary is still found. Case folding is ASCII —
  non-ASCII text matches exactly, but not case-insensitively.
