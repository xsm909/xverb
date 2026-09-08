# Sound

A file you can hear, and see the shape of. The machine's own engine plays it —
`AVAudioPlayer` on macOS, Media Foundation on Windows, GStreamer on Linux — so
the formats are the ones that machine already reads: mp3, wav and m4a
everywhere, flac on both recent systems, aiff and caf on the Mac, wma on
Windows, and on Linux whatever GStreamer has plugins for.

Space plays and pauses. `W` shows how loud the file is over its length and `S`
shows which frequencies are in it, a slice of time at a time. The arrows seek — a second with Shift, thirty with
Ctrl — and the digits jump through the file in tenths. Up and down are the
volume, which is the application's own and is remembered. A press anywhere on
the waveform goes there.

Escape goes back, and going back is silent.

No code, so it loads on every platform the application runs on. What the file's
tags say it is called, and who played it, is a different question — that is a
plugin that reads the format, not this one.
