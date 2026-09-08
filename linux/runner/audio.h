#ifndef RUNNER_AUDIO_H_
#define RUNNER_AUDIO_H_

#include <flutter_linux/flutter_linux.h>

// Plays a sound file over the `xverb/audio` channel, and reports the shape
// and the frequencies of it for the drawing.
//
// GStreamer does all three: `playbin` is the player every desktop on this
// platform already uses, and `decodebin` into an `appsink` is the decoder. So
// what can be played on a machine is whatever that machine has plugins for —
// the same arrangement the other two runners have with AVFoundation and Media
// Foundation, and the same honest answer when it has none.
//
// **Built only where GStreamer's headers are.** A Linux without the development
// packages still builds the application; the channel is registered either way
// and answers that it cannot play, which is what the viewer already knows how
// to say. See `XVERB_HAS_GSTREAMER` in the runner's CMakeLists.
void register_audio_channel(FlBinaryMessenger* messenger);

#endif  // RUNNER_AUDIO_H_
