# The picture on the About form

`splash.png`, drawn across the top of the card at **620 × 250** logical points.

**Supply it at 1240 × 500**, which is that size at two times — every screen this
runs on is either 2x, where it lands pixel for pixel, or 1x, where it comes down
cleanly by half. One file rather than a 1x and a 2x: a second file is a second
thing to keep in step, and downscaling by an exact half costs nothing anybody
can see.

**A plain rectangle.** The card rounds its own top corners and clips the picture
to them, so nothing has to be cut out and no transparency is needed.

## Two places on it are spoken for

- **Top right: the version**, in a thin white face with a shadow under it. It
  wants about 90 × 20 points of quiet — the sky, a wall, anything without
  detail.
- **Along the bottom left: one line about the picture**, smaller and quieter
  again, from `caption.txt` beside this file.

Everything between the two is the picture's.

## caption.txt

One line, written as it should be read. **A caption rather than a credit**: it
is not always a name — a photograph you took yourself has no author to name, and a
place is often the better line. `Photo by Someone`, or `Kotor, 2026`, or the
name on its own. Whatever is in the file is what is drawn.

**No file, or an empty one, and nothing is drawn.** That is an ordinary state
rather than a failure: a picture with nothing worth saying about it needs no
line under it.

It lives here rather than in the source so that the picture and its line travel
together — replacing one is replacing the other, in this folder, with nothing to
find in the code.

## Until the picture is here

The form paints a gradient in the palette's own colours and puts the wordmark on
it in one colour. Nothing breaks without the file, and there is a test that says
so.
