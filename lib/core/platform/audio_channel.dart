import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// What the machine's own audio engine said about a file it agreed to play.
///
/// Everything here comes from the decoder rather than from the bytes: the
/// container may say one thing and the stream another, and the number that
/// matters is the one whatever is about to make sound believes.
class AudioTrack {
  const AudioTrack({
    required this.duration,
    required this.sampleRate,
    required this.channels,
    this.codec = '',
    this.bitrate = 0,
    this.bits = 0,
    this.bytes = 0,
  });

  factory AudioTrack.fromMap(Map<Object?, Object?> map) => AudioTrack(
        duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
        sampleRate: (map['sampleRate'] as num?)?.toDouble() ?? 0,
        channels: (map['channels'] as num?)?.toInt() ?? 0,
        codec: map['codec'] as String? ?? '',
        bitrate: (map['bitrate'] as num?)?.toInt() ?? 0,
        bits: (map['bits'] as num?)?.toInt() ?? 0,
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      );

  final Duration duration;

  /// Frames a second, as a double because 44100 is not the only number in use
  /// and 11025.5 exists in the wild.
  final double sampleRate;

  final int channels;

  /// What the stream is written in, in the engine's own words — `mp3`, `aac`,
  /// `alac`, `flac`, `lpcm`. Four characters on both platforms, by coincidence
  /// of both of them having grown out of QuickTime-era tagging.
  final String codec;

  /// Bits a second, or 0 where the engine will not say. Uncompressed audio has
  /// one by arithmetic and compressed audio has one by measurement, so this is
  /// whichever the platform could answer without decoding the file twice.
  final int bitrate;

  /// Bits a sample for uncompressed audio, 0 for everything else — a number
  /// that means nothing for a codec that does not work in samples.
  final int bits;

  /// How big the file is. Asked of the platform along with the rest rather than
  /// of the disk here: the drawing then needs no file system at all, which is
  /// also what makes it something a test can pump.
  final int bytes;
}

/// Where the sound has got to, sent from the platform rather than counted here.
class AudioTick {
  const AudioTick({
    required this.position,
    required this.playing,
    required this.ended,
  });

  factory AudioTick.fromMap(Map<Object?, Object?> map) => AudioTick(
        position: Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
        playing: map['playing'] as bool? ?? false,
        ended: map['ended'] as bool? ?? false,
      );

  final Duration position;
  final bool playing;

  /// The file has run out. Sent once, so whoever is listening can stop rather
  /// than watch the position sit at the end.
  final bool ended;
}

/// Talks to the runner's own audio channel.
///
/// **The machine plays the file; this only asks it to.** No decoder, no mixer
/// and no third-party binary in the bundle: `AVAudioPlayer` on macOS, Media
/// Foundation on Windows and GStreamer on Linux, exactly as the picture viewer
/// leans on ImageIO and WIC. What a given machine can play therefore belongs to
/// that machine, and [open] returning null is the honest answer rather than a
/// failure — including on a Linux built without GStreamer's own development
/// packages, where the channel is there and says it cannot play.
///
/// One file at a time, and that is deliberate: two sounds at once out of a file
/// manager is a defect however it happens, so opening a second file closes the
/// first inside the native half.
class AudioChannel {
  AudioChannel._();

  static final AudioChannel instance = AudioChannel._();

  static const MethodChannel _channel = MethodChannel('xverb/audio');
  static const EventChannel _ticks = EventChannel('xverb/audio/ticks');

  /// The platforms whose runner carries the native half. Anywhere else the
  /// viewer draws the file and says it cannot be played here, which is what a
  /// build with no runner of ours does.
  static bool get isAvailable =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Stream<AudioTick>? _stream;

  /// Where the sound has got to, as the platform reports it — about ten a
  /// second, which is often enough to keep a local clock honest and rare enough
  /// to cost nothing. Whoever draws interpolates between two of these.
  Stream<AudioTick> get ticks => _stream ??= _ticks
      .receiveBroadcastStream()
      .map((event) => event is Map
          ? AudioTick.fromMap(event)
          : const AudioTick(
              position: Duration.zero,
              playing: false,
              ended: false,
            ))
      .asBroadcastStream();

  /// Hands [path] to the machine's engine and reports what it made of it.
  ///
  /// Null means this machine does not read that sound — not that the file is
  /// broken. The same file on the other desktop may well play.
  Future<AudioTrack?> open(String path) async {
    if (!isAvailable) return null;
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>(
        'open',
        {'path': path},
      );
      return answer == null ? null : AudioTrack.fromMap(answer);
    } on Object {
      return null;
    }
  }

  Future<void> play() => _tell('play');

  Future<void> pause() => _tell('pause');

  /// Where in the file to be. Clamped by the native half, because a seek past
  /// the end is a natural consequence of holding an arrow key down.
  Future<void> seek(Duration where) =>
      _tell('seek', {'positionMs': where.inMilliseconds});

  /// 0..1, the application's own — nothing here touches the system's mixer or
  /// the volume of anything else the machine is playing.
  Future<void> setVolume(double volume) =>
      _tell('volume', {'volume': volume.clamp(0.0, 1.0)});

  /// Stops and lets go of the file. Called when the viewer closes, which is
  /// the rule: Escape goes back, and going back is silent.
  Future<void> close() => _tell('close');

  /// The shape of the sound over the whole file: [buckets] pairs of peak and
  /// average, 0..1, taken from the decoded samples.
  ///
  /// Measured on the Mac before this was written: a full sweep of a ten-minute
  /// file is 61 ms uncompressed and 388 ms as AAC. So it is done once when the
  /// file opens, with nothing cached and nothing to wait for.
  ///
  /// **Asked for finely, drawn coarsely.** The buckets are hundredths of a
  /// second rather than pixels, because the drawing needs two different things
  /// out of the same sweep: a shape to paint, which is pooled down to the width
  /// of the window, and how loud the music is at this instant, which is read at
  /// the playhead. A platform meter would have given the second one — but only
  /// on the Mac, and on Windows it would have measured every other application
  /// on the machine along with ours.
  Future<Float32List?> envelope(String path, int buckets) async {
    if (!isAvailable) return null;
    try {
      final answer = await _channel.invokeMethod<Float32List>(
        'envelope',
        {'path': path, 'buckets': buckets},
      );
      return answer != null && answer.length >= buckets * 2 ? answer : null;
    } on Object {
      return null;
    }
  }

  /// The file seen as frequencies rather than as loudness: [columns] slices of
  /// time, each holding [bands] values from low to high, 0..1 off a decibel
  /// scale.
  ///
  /// **The whole file at once, not what is playing right now.** A meter that
  /// dances to the moment cannot be looked at — it is gone before it is read —
  /// and it would have to come across the channel sixty times a second to
  /// exist at all. A picture of the whole thing can be looked at, seeked
  /// through, and compared with itself, and it costs one sweep of the decoder
  /// that is already being made for the shape.
  ///
  /// Asked for only when somebody switches to it, because unlike the shape it
  /// is not needed to play a file.
  Future<Float32List?> spectrum(String path, int columns, int bands) async {
    if (!isAvailable) return null;
    try {
      final answer = await _channel.invokeMethod<Float32List>(
        'spectrum',
        {'path': path, 'columns': columns, 'bands': bands},
      );
      return answer != null && answer.length >= columns * bands ? answer : null;
    } on Object {
      return null;
    }
  }

  Future<void> _tell(String method, [Map<String, Object?>? arguments]) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // A missing channel is a build without the native half, which the viewer
      // has already been told about by [isAvailable]. Nothing to report twice.
    }
  }
}
