# What xverb does that others do not

A running list of the things worth showing someone. Not a manual and not a
changelog — those are elsewhere. This is the short answer to "why would I use
this instead of the one I already have", written down as each answer arrives so
that none of them is forgotten by the time there is a site to put them on.

**How to add to it.** One heading per thing, and under it: what it is in a
sentence, then *why it is not what everyone else does*. The second part is the
whole point — a feature that every file manager has does not belong here however
well it works. Say plainly where something is only half true, because the first
person to try it will find out anyway and it is cheaper to have said so.

---

## Looking at photographs

A folder of pictures is walked with the arrow keys, full screen, with a strip of
the neighbours standing on the picture itself.

**The arrows mean the same thing either side of F3.** Down in a listing is the
next file; press F3 on it and Down is still the next file. A picture bigger than
the window would otherwise pan with the arrows, so the same key would mean two
things across one press — and the strip is what settles it, by being visible.
While it is up the arrows walk the folder and the picture is panned with Shift
or with the hand; `T` puts the strip away and all four are the picture's again.
The rule is never in anybody's memory: it is on the screen.

**It has no band, no bar and no panel.** The picture runs the whole height of
the window and passes underneath the thumbnails, which stand on it, held apart
by a shadow and a frame. A strip in a bar of its own would take height away from
the thing being looked at in order to say nothing.

**A thumbnail is the shape of its picture, and they stand on one floor.** A
portrait fills the height and is narrow, a landscape runs out of width first and
stands lower — a street of houses at different heights. Verticals and
horizontals are told apart without looking twice, which a row of identical
squares cannot do.

**Nothing blinks.** Walking to the next photograph does not empty the page: the
one on screen stays until the next is ready, and the new one arrives *over* it.
The outgoing picture holds full opacity until the last fifth of the fade —
two pictures crossing at half opacity each are together dimmer than either was
alone, and that dip is a blink drawn slowly.

**A photograph opens filling the window — edge to edge, no bands.** Three sizes
rather than two. Fit takes the smaller of the two ratios so the whole picture is
inside the window, and never enlarges: right for a sixteen-pixel icon, wrong for
a photograph. Fill takes the larger, so the *window* is inside the picture and
there is nothing down the sides; what runs off the edge is still reachable with
the arrows. 1:1 counts device pixels, so one pixel of the file lands on one pixel
of the screen and nothing is resampled. Whichever is chosen is remembered, for
the next picture and the next session.

**On a Mac the trackpad does what a Mac trackpad does.** Pinch magnifies, two
fingers push the picture about, and a sideways slide with nowhere left to push
opens the neighbouring file — the same rule the arrows keep, and the strip on
screen is what makes it readable. A mouse wheel still steps the magnification,
because a wheel and a trackpad are different devices and have no business
behaving alike. None of it costs the other platforms anything: these events
exist only where the machine sends them.

**The panel comes back to where you were.** The cursor follows the reader
through the folder, so leaving the viewer leaves you standing on the photograph
you stopped at — and the panel opens there next time the application is started.
Remembered by name rather than by row, so a folder that has changed underneath
does not put the cursor on a stranger.

**Formats.** Whatever the machine's own decoder reads — png, jpeg, gif, bmp,
tiff, heic — plus, through a plugin that decodes them itself and is therefore
identical on every platform, Photoshop `.psd` and `.psb`, Targa, TIFF and GIMP's
`.xcf`, layers, blend modes and all.

*Half true, and worth saying:* a thumbnail comes from the machine's decoder, so
a format only the plugin can read shows the file's name instead of a picture —
`.xcf` everywhere, `.tga` and `.psd` on Windows. Asking a plugin for a small
copy is a change to the plugin contract and has not been made. And a folder of
`.jpg` beside `.heic` is two strips rather than one, because those extensions
are claimed by different plugins.

---

## Everything is a plugin, and there are two kinds

The core manages files in two panels. Network transports, viewers, editors,
archives — every one of them is an extension, the way it works in Blender.

**Two runtimes, and you take the weaker one that does the job.** A *Python
plugin* runs arbitrary code in its own process. A *declarative extension* is
pure JSON that composes the host's own render primitives — no code and no
interpreter, so it loads on platforms where executing plugin code is impossible
at all. Blender makes the same trade with node groups and theme extensions.

**The proof is that FTP is a plugin.** Not because it had to be, but so that the
plugin surface has to be good enough to build a real file system on. A viewer
plugin gets the same deal: it returns one of a handful of content shapes and the
host draws it, so a plugin author never writes a widget.

---

## The appearance is pressed, not configured

Every colour in the application is chosen by pointing at the thing it paints in
a live preview of the window, rather than by finding a row named after it in a
list. When something has no colour of its own yet, the answer is to grow it in
the preview — which is how the preview came to have a console, a menu, a reading
page and a hint standing in it.

Colours come in pairs, a fill and its ink together, never one without the other:
a palette that recoloured a surface and left the writing on it unreadable is not
a palette. A saved palette carries the **whole** appearance — font, density,
opacity, every pair — by construction rather than by a list somebody has to
remember to extend, and it is a file, so it can be passed around.

---

## Nothing changes in a single frame

Every change is animated, on one scale the user sets, and every movement has to
*state something true*. A listing being left goes out and the one arrived in
comes in; opening a folder moves forward and leaving one moves back, so the
direction says which way you went. At Off nothing runs at all — off means off,
not "very fast".

---

## The keyboard reaches everything

Escape goes back, one thing at a time. Every switch has a letter and every
letter is shown next to the switch that does the same thing, because a control
only the mouse can reach is not a control. The orthodox commander bindings are
where they have always been.

---

## Reading a file is a first-class thing

The viewer is a place you go to and come back from, not a window floating over
the panels. Code is coloured by grammars that ship **as data in a plugin**,
scanned by one scanner in the host, and a grammar names *roles* rather than
colours — so the palette decides what a keyword looks like and a new language is
a file rather than a release. Long documents grow a structure panel read out of
that same colouring, and a held heading is the heading itself rather than a
strip that looks like one.

## A PDF is shown as a document, not as a page

F3 on a PDF gives the text of it — headings, lists and tables, with the running
heads, the page numbers and the line breaks of the page measure thrown away. A
word broken across two lines is put back together; a page set in two columns is
read down its columns rather than across them; a table is a table, with its
cells intact and no head invented for it where the document had none.

**Every other reader draws the page, and drawing the page is the problem.** A
PDF is a set of instructions for putting marks on paper, so a viewer that
follows them faithfully hands you back the paper — the margins, the furniture,
the measure somebody chose for print, and a line break every sixty characters
that no reader wants. When you *do* want the page as it stands, Enter opens it
in whatever this machine already opens PDFs with, and a browser draws it better
than we would. What was missing was the other reading, and that is this one.

**Nothing is rendered and nothing third-party ships.** No PDFium, no system
engine, no raster mode. The reader is Python on the standard library, about two
thousand lines, and it is identical on all three systems — which also means RC4
and AES had to be written out, because a locked PDF is usually locked with an
empty password and every other reader opens it without asking.

**Where it is only half true.** Roughly two documents in five carry the tags
that say what is a heading and what is a table, and for those the reading is
simply right. Without them it is worked out from the grid the page draws, and
failing that from where the words sit — a guess, and the reading says at the top
when it is one. **A scan has no text in it at all** and this says so in a
sentence rather than showing an empty page; in one measured collection that was
half the pages there were.
