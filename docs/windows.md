# Internal windows

The connection forms, the copy progress, the search and everything that asks a
question open as windows *inside* the commander. They have a title bar, they
drag, they resize, they stack, and on a phone-sized layout they simply fill the
screen.

## Why not dialogs

A file manager wants more than one thing on screen. Watching a copy while
browsing, keeping a search open while working through its results, comparing
two viewers — a modal route forbids all of it.

## The title bar problem, and how a page gets around it

There used to be a second reason, and it was a bug report: the application
draws its own title bar because the native one is hidden, a `MaterialPageRoute`
covers the whole client area including that bar, and so while a full-screen
page was open **the window could not be moved**.

That is a property of pages that cover the bar, not of pages. A page that draws
a [`TitleBar`] of its own along its top has one in the same place, and it is
the same widget, so the window drags, maximises and closes from inside the page
exactly as it does from the panels. The viewer has always worked this way, and
settings followed once it was clear the trick was general.

So the rule is not "windows, never pages". It is: **anything covering the whole
client area draws the title bar itself.**

## The pieces

| Where | What it does |
| --- | --- |
| `lib/state/window_stack.dart` | `DeskWindow` (one window: title, geometry, contents) and `WindowStack` (what is open, in z-order) |
| `lib/ui/windows/window_layer.dart` | Draws the stack over the desk; decides floating vs full-screen |
| `lib/ui/windows/window_frame.dart` | The chrome: title bar, buttons, drag, eight resize grips |
| `lib/ui/windows/window_dialogs.dart` | `showDeskWindow` — a window that hands a value back, the way a dialog does |

Geometry lives on `DeskWindow`, not in the widget, so a drag survives the
panels underneath refreshing mid-gesture. Each window is its own
`ChangeNotifier`, so dragging one repaints that window rather than the desk.

The stack is bottom-to-top; the last entry is the front window and owns the
keyboard. `CommanderScreen` ignores every key while any window is open, so
nothing leaks through to the panels behind.

## Modal windows

`DeskWindow.modal` drops a barrier immediately *below* the front-most modal
window — not over the whole desk, so a question asked on top of a modal window
is still answerable. `showDeskWindow` is modal by default, since it exists for
things that are waiting on an answer.

`onDismiss` changes what Escape and the close button mean. The copy progress
window uses it to cancel the operation, because a copy running with no window
attached to it is worse than either finishing or stopping.

## Full-screen below 720×480

There is no room to float anything on a phone, so the layer switches: the front
window fills the desk, loses its drag and resize gestures, and the ones behind
it stay mounted but offstage. Nothing else changes — the same widgets, the same
window objects.

## What is deliberately *not* a window

Viewing a file (F3) and the settings (F9) are pushed pages. Both are somewhere
you go and come back from, both want the whole area, and a frame floating over
the listing adds nothing to either. Both draw the application's title bar
themselves, so the window is still draggable from inside them.

Settings held out as a window for a while on the argument that you change a
colour and want to see it land on the panels behind. The preview in the
appearance settings answers that better than the panels did: it shows a cursor
row, a marked row and a shaded one at once, which a real listing rarely does.

## Ids

Opening a window with an id that is already open brings the existing one
forward instead of stacking a duplicate. That is what keeps a second viewer
from opening on the same file. Transient questions leave the id out and get a
fresh window each time.

## The blur, and what it can and cannot do

Menus and windows blur what is behind them with `BackdropFilter`. On a
translucent window (acrylic or mica) that blur is much weaker, and the reason
is worth writing down because it looks like a bug:

`BackdropFilter` blurs *what Flutter painted*, then draws the result over it.
The desktop showing through an acrylic window was never painted by Flutter — it
is composited by Windows behind the window — so no filter in the app can reach
it. With the panels at 20% opacity, four fifths of what shows through a menu is
that untouchable layer, and one pass of blur adds a nearly transparent smear on
top.

The menus compensate by applying the blur several times when the window is
translucent (`_blurPassesFor` in `context_menu.dart`); each pass compounds the
coverage of the app's own content. Raising **panel opacity** in the appearance
settings does more than anything else here: it decides how much there is to
blur in the first place.

### And what the window itself is blurred with

Two Windows changes bite here at once.

From build 22523, `flutter_acrylic` stops using the composition attribute for
`acrylic` and `mica` and asks DWM for a system backdrop instead. DWM will not
paint one on a window whose frame we removed in order to draw our own title
bar, so through the package those two effects cannot work here at all.

And `ACCENT_ENABLE_BLURBEHIND` — the legacy effect the app fell back to because
of that, and ran on for a long time — **is no longer honoured on Windows 11**.
It does not blur and it barely lets anything through. That is the whole reason
the backdrop looked like it had never come on.

The measurement, on build 26200: flip the screen behind an untouched window
between white and black, sample the same patch inside the window, and take the
difference in mean brightness.

| accent | delta | |
| --- | --- | --- |
| `ACCENT_ENABLE_ACRYLICBLURBEHIND` | 35 | the desktop reaches the window |
| `ACCENT_ENABLE_BLURBEHIND` | 7 | as good as opaque |
| `ACCENT_DISABLED` (control) | 0 | the probe is sound |

So both blurring backdrops ask for real acrylic, which only our own channel can
reach, and Mica degrades to the same thing on Windows.

### Checking it, so it stops coming back

`tool/backdrop_probe.ps1` turns "the window looks a bit dark" into a number.
Close the app and run it:

```
powershell -File tool\backdrop_probe.ps1
```

It puts a full-screen window behind the app that flips between white and black,
and samples a patch **inside** the app in both phases. The app's own content is
identical either way, so it cancels out and what is left is the backdrop. It
then repeats the reading after each thing that has historically dropped the
effect, and exits non-zero if any of them lost it:

```
state                          delta   verdict
fresh                              40  ok
after a title-bar drag             40  ok
after a programmatic move          40  ok
after a programmatic resize        40  ok
maximised                          40  ok
restored from maximised            40  ok
restored from minimised            34  ok
```

Point it at a build asking for the old `ACCENT_ENABLE_BLURBEHIND` and every row
reads 8 and it fails, which is how we know the threshold separates the two.

### What it measured about light palettes

A light palette passes about **half** as much of the desktop through as a dark
one: 40 against 20, same effect, same window, only the palette pinned
differently (`-Palette light` is the Xverb Light preset).

That is worth writing down because it was first reported — by me — as "acrylic
is nearly invisible on a light theme", which it is not. It is present and
weaker. The tint is not the cause: taking it from 15% down to 2% moved the
reading not at all, on either palette.

And that last result needs a caveat, or it will be misread later. The probe
measures the *difference* between the white and the black phase, so any layer
that is constant across both — the tint, most obviously — cancels out by
construction. The number says the tint does not change how much contrast
reaches through. It says nothing about how the tint looks, which is what a tint
is for. Do not reach for this tool to answer that question.

The lever that does change how much shows through is **panel opacity**, which
decides how much of the window is the app's own paint in the first place.

Three things it has to do, each of which cost a wrong answer first:

- **Pin the whole palette, not just the backdrop.** The tint comes from the
  panel colour, and a near-white one (the Xverb Light preset) washes the reading out
  until a working acrylic scores the same as a broken one. The probe forces a
  dark palette and a low panel opacity, and puts the user's settings back.
- **Lift the app into the topmost band.** Otherwise whatever the developer has
  open sits in front of the flipping screen, part of the window is measured
  against something that never flips, and a healthy backdrop reads as dead.
- **Never move the window between two samples.** Read one half over a light
  area and the other over a dark one and the two readings come from two
  different window states. Keep the window still; change what is behind it.

### Why the runner applies it, not the package

`windows/runner/backdrop.cpp` is a channel of our own that calls
`SetWindowCompositionAttribute` directly. It exists because `flutter_acrylic`
writes `ACCENT_DISABLED` to the window before every effect it sets — one call
to blank, one to apply. DWM composes a frame from the state in between, so
**every re-apply flashed the bare window**. One write, no intermediate state,
no flash.

`WindowService` still goes through the package on macOS and Linux, and falls
back to it on a Windows that will not give up the entry point.

### Losing the backdrop, and not mistaking a drag for it

Locking the session, a remote desktop connection and DWM restarting all drop
the effect without announcing it. Regaining focus is the one signal that
arrives afterwards in every one of those cases, so the backdrop is re-asserted
there, throttled to once every few seconds — and **View → Window backdrop →
Re-apply the backdrop** is the button for when even that was not enough.

Focus is a noisy signal, though: pressing the title bar to drag the window
raises `WM_NCACTIVATE`, which arrives as a focus event a moment *before* the
move starts. That is how a re-apply — and, until the runner took the job over,
a visible flash — landed on the user every time they picked the window up.
`app.dart` therefore waits out `_gestureGrace` before acting on a focus event
and drops it if a `WM_MOVING`/`WM_SIZING` follows, and ignores focus outright
while a drag is in flight.

`window.log` records all of it. A healthy drag looks like this, with nothing
applied in between:

```
  1058ms  first frame -> blurBehind ok (native)
  3938ms  event: move started
  4826ms  event: moved
```
