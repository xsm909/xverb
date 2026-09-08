#ifndef RUNNER_FILE_TRANSFER_H_
#define RUNNER_FILE_TRANSFER_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The file clipboard and drag-and-drop, over the `xverb/transfer`
// channel.
//
// GTK does the dragging and owns the clipboard; this says which files and
// answers what the drop would do. The one question it cannot answer itself is
// which folder inside the window the pointer is over, and that is the question
// it asks Dart.
//
// Two conventions of this desktop are honoured rather than invented: files
// travel as a `text/uri-list`, and a cut is written as
// `x-special/gnome-copied-files` — the format the file managers on this
// platform read, whose first line is the word `copy` or `cut`.
void register_transfer_channel(FlView* view);

#endif  // RUNNER_FILE_TRANSFER_H_
