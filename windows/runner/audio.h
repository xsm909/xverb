#ifndef RUNNER_AUDIO_H_
#define RUNNER_AUDIO_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Plays a sound file over the `xverb/audio` channel, and reports the shape
// of it for a waveform.
//
// Media Foundation does both: `IMFMediaEngine` is the player the system's own
// browser uses, and `IMFSourceReader` is the decoder. So what can be played on
// a machine is whatever that machine reads — the same arrangement the picture
// viewer has with WIC, and the same honest answer when it reads nothing.
//
// Nothing here knows what an mp3 is.
void RegisterAudioChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_AUDIO_H_
