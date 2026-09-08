import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/audio_channel.dart';
import '../../core/plugins/viewer.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/vfs_path.dart';
import '../format.dart';
import '../motion.dart';
import '../widgets/hint.dart';
import '../widgets/viewport_chrome.dart';
import 'reading_colours.dart';

/// A sound: played by the machine's own engine, drawn as its own shape.
///
/// **Three things happen here and only one of them is clever.** The machine
/// plays the file (see [AudioChannel]) and the machine decodes it into samples;
/// what is written here is the drawing — the shape of the whole file, where the
/// playhead is in it, and how loud the music is at that instant.
///
/// The playhead runs on real time and is **not** scaled by the animation speed
/// setting. A movement that states where in a piece of music you are is a fact
/// about the file, and slowing it down would make the drawing say something
/// untrue; the interface's own movements — the shape arriving, a control
/// appearing — obey the setting as everything else does.
class AudioView extends StatefulWidget {
  const AudioView({
    super.key,
    required this.content,
    this.hasKeyboard = true,
  });

  final ViewerContent content;

  /// Whether this drawing has the keyboard.
  ///
  /// **It also decides whether the sound starts by itself**, and that is the
  /// rule for the panel viewport: in Ctrl+Q the panel keeps the keys and moving
  /// the cursor would otherwise fire off a sound per file. Full screen, the
  /// file was opened to be heard, so it plays.
  final bool hasKeyboard;

  @override
  State<AudioView> createState() => _AudioViewState();
}

class _AudioViewState extends State<AudioView>
    with SingleTickerProviderStateMixin {
  final AudioChannel _sound = AudioChannel.instance;

  /// Held rather than looked up when it is needed: the volume is written after
  /// the platform has been told about it, and a widget that has gone away by
  /// then has no context to ask with.
  late final SettingsStore _settings;

  AudioTrack? _track;
  String? _trouble;

  /// **Taken, not asked for** — the same rule the picture canvas states: a
  /// viewer opens inside the scope F3 was pressed in rather than as a route of
  /// its own, so `autofocus` lands nowhere and the keys go to whatever had them
  /// before. The first version of this file asked, and Space did nothing at all
  /// in the running application while every test passed, because a test's tree
  /// has nothing else in it to hold the focus.
  final FocusNode _keys = FocusNode(debugLabel: 'sound');

  /// Pairs of peak and average over the whole file, a hundredth of a second
  /// each. Pooled down to the bars that fit the window when it is drawn, and
  /// read at the playhead for how loud it is now — see [AudioChannel.envelope].
  Float32List? _shape;

  /// The loudest sample in the file, and what the drawing is multiplied by to
  /// make that sample reach the top of the window.
  ///
  /// **Measured before this was written, and it decided the design.** A speech
  /// recording out of the system's own frameworks peaks at 0.023 and a system
  /// alert sound at 0.198 — drawn on a plain 0..1 scale both are a flat line,
  /// which reads as a broken viewer rather than as a quiet file. So the shape is
  /// normalised to its own loudest moment, which keeps every proportion inside
  /// the file true, and how loud the file actually is is said as a number
  /// beside it instead of being left for the eye to fail to see.
  double _peak = 0;

  /// Where the file is, kept because the frequencies are asked for later than
  /// the shape — when somebody switches to them.
  String? _path;
  StreamSubscription<AudioTick>? _ticks;
  late final Ticker _clock;

  /// The last thing the platform said, and how long ago it said it. The
  /// position drawn is the sum of the two: ten reports a second is enough to
  /// keep a local clock honest, and a clock is what makes the playhead smooth.
  Duration _reported = Duration.zero;
  final Stopwatch _since = Stopwatch();
  bool _playing = false;
  bool _ended = false;

  /// The last thing the platform said, kept apart from [_reported] because a
  /// seek writes that one itself — this is the platform's own clock and nobody
  /// else's.
  Duration _said = Duration.zero;

  /// Whether that clock has been seen to move since play was asked for.
  ///
  /// **Measured, and it is why the playhead used to jerk on the first press.**
  /// A media engine is handed the file and told to play in the same breath, and
  /// on Windows it took some six hundred milliseconds to actually start: it
  /// reported nought, then nought, then nought again while the local clock had
  /// already run to a tenth of a second and more, so every report threw the
  /// playhead back to the beginning: forward, back, forward, and the log said
  /// the same thing in numbers.
  ///
  /// So the local clock is not a clock until the platform's has moved. Until
  /// then the playhead stands where it stands, which is the truth: nothing is
  /// coming out of the speakers yet.
  bool _moving = false;

  /// The file as frequencies: [_bands] values per slice of time, low to high,
  /// already turned into a picture the canvas can stretch.
  ///
  /// Null until somebody asks for it. Unlike the shape it is not needed to play
  /// anything, and a sweep nobody looks at is a sweep not worth making.
  ui.Image? _picture;
  bool _picturePending = false;
  ReadingColours? _paintedWith;
  bool _spectrum = false;

  /// **Forty-eight was not enough to look at.** Stretched over the height of a
  /// window each band was ten pixels of blur, and the picture came out as a
  /// smear rather than as a spectrum. This is about one band per two pixels of
  /// a real window, which is where the
  /// harmonics of a voice start being separate lines instead of a haze.
  static const int _bands = 192;

  /// What the drawing multiplies the samples by. One where the file is silent,
  /// so a silent file is a flat line rather than an amplified nothing.
  double get _gain => _peak > 0.0005 ? 1 / _peak : 1;

  /// How loud it is, and the same figure with a follower on it — an ear does
  /// not hear a bar chart flickering, so the drawing rises quickly and falls
  /// away slowly.
  double _level = 0;
  double _volume = 0.7;

  /// Whether the volume was last changed by a hand on the selector rather than
  /// by a key or the wheel. A drag follows the finger and must not be animated
  /// behind it; a step is a change and animates like everything else.
  bool _volumeDragged = false;

  /// How much of the shape has arrived, 0..1. Its only job is to let the
  /// drawing appear rather than snap in, which is the one movement here that
  /// answers to the animation setting.
  double _arrived = 0;

  @override
  void initState() {
    super.initState();
    _clock = createTicker(_onFrame);
    _settings = context.read<SettingsStore>();
    _volume = _settings.soundVolume;
    _spectrum = _settings.soundSpectrum;
    _takeKeyboard();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(AudioView old) {
    super.didUpdateWidget(old);
    if (widget.hasKeyboard && !old.hasKeyboard) _takeKeyboard();
    if (old.content.url != widget.content.url) {
      unawaited(_sound.close());
      _picture?.dispose();
      setState(() {
        _track = null;
        _shape = null;
        _picture = null;
        _trouble = null;
        _arrived = 0;
        _reported = Duration.zero;
        _said = Duration.zero;
        _moving = false;
        _playing = false;
        _ended = false;
      });
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    // **Going back is silent.** Escape closes the page and the sound stops with
    // it; a viewer that goes on playing behind a closed window is a background
    // player, which is a different thing with its own settings and its own way
    // of being stopped.
    _ticks?.cancel();
    _clock.dispose();
    _keys.dispose();
    _picture?.dispose();
    unawaited(_sound.close());
    super.dispose();
  }

  void _takeKeyboard() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_keys.hasFocus) {
        _keys.requestFocus();
      }
    });
  }

  // MARK: opening

  Future<void> _load() async {
    final url = widget.content.url;
    if (url == null || url.isEmpty) {
      setState(() => _trouble = tr('The viewer did not say which sound to play.'));
      return;
    }
    if (!AudioChannel.isAvailable) {
      setState(() => _trouble = tr('This build cannot play sound.'));
      return;
    }

    final path = VfsPath.parse(url).toNativePath();
    _path = path;
    final track = await _sound.open(path);
    if (!mounted) return;
    if (track == null) {
      setState(() => _trouble = tr('This sound could not be read on this machine.'));
      return;
    }
    setState(() => _track = track);

    await _sound.setVolume(_volume);
    _ticks = _sound.ticks.listen(_onTick);
    if (widget.hasKeyboard) await _play();

    // The shape comes second on purpose: the sound is what was asked for, and
    // waiting for a picture of it before making any would be the wrong way
    // round. A ten-minute file is decoded in tens of milliseconds either way.
    final buckets = _bucketsFor(track.duration);
    final shape = await _sound.envelope(path, buckets);
    if (!mounted || shape == null) return;
    var peak = 0.0;
    for (var i = 0; i < shape.length; i += 2) {
      if (shape[i] > peak) peak = shape[i];
    }
    setState(() {
      _shape = shape;
      _peak = peak;
    });
    _fadeShapeIn();
    // The frequencies only if that is what is being looked at — a sweep nobody
    // looks at is a sweep not worth making.
    if (_spectrum) unawaited(_askForSpectrum());
  }

  /// The frequencies, decoded once and drawn as an image.
  ///
  /// **A picture rather than a grid of rectangles.** Twelve hundred columns of
  /// forty-eight bands is fifty-seven thousand shapes; painted every frame that
  /// is a canvas that cannot keep up with its own playhead. Built once, it is
  /// one `drawImageRect` — and the same picture stretches to any window.
  Future<void> _askForSpectrum() async {
    final path = _path;
    final track = _track;
    if (path == null || track == null || _picturePending) return;
    // **Read, not watched.** Asking for the colours the ordinary way subscribes
    // this context to the settings, and a subscription taken outside a build is
    // an assertion the moment somebody presses the switch.
    final colours = readingColours(context, watch: false);
    if (_picture != null && _paintedWith == colours) return;
    _picturePending = true;

    // About eighty slices a second — a column per pixel of a wide window, for
    // the same reason as the bands. The ceiling is for the long files, where no
    // eye could tell the difference anyway.
    final columns =
        (track.duration.inMilliseconds / 12.5).round().clamp(400, 6000);
    final picture = await _sound.spectrum(path, columns, _bands);
    if (!mounted || picture == null) {
      _picturePending = false;
      return;
    }
    final image = await _paintSpectrum(picture, columns, _bands);
    _picturePending = false;
    if (!mounted) {
      image?.dispose();
      return;
    }
    _picture?.dispose();
    setState(() {
      _picture = image;
      _paintedWith = colours;
    });
  }

  /// The matrix as pixels: one per band per slice, on the thermal scale.
  static Future<ui.Image?> _paintSpectrum(
    Float32List values,
    int columns,
    int bands,
  ) async {
    // Normalised to its own loudest cell, for the reason the shape is: a file
    // recorded quietly is not a file with nothing in it, and a spectrum drawn
    // against full scale shows nothing at all for most real recordings.
    var top = 0.0;
    for (var i = 0; i < columns * bands; i++) {
      if (values[i] > top) top = values[i];
    }
    final gain = top > 0.02 ? 1 / top : 1.0;

    final pixels = Uint8List(columns * bands * 4);
    for (var column = 0; column < columns; column++) {
      final before = column > 0 ? column - 1 : 0;
      final after = column < columns - 1 ? column + 1 : columns - 1;
      for (var band = 0; band < bands; band++) {
        // Three slices, weighted towards the middle one. A hundredth of a
        // second either side is below anything an eye can place in time, and
        // it takes the flicker out of a picture whose columns are single
        // pixels — while an onset, which is many bands at once, survives it.
        final smoothed = (values[before * bands + band] +
                values[column * bands + band] * 2 +
                values[after * bands + band]) /
            4;
        final value = (smoothed * gain).clamp(0.0, 1.0);
        // Bands run low to high and a picture's rows run top to bottom, so the
        // first band belongs to the last row — otherwise every spectrum in the
        // application is upside down and looks merely unfamiliar.
        final row = bands - 1 - band;
        final at = (row * columns + column) * 4;
        // The bottom of the scale is the noise every recording has; drawn, it
        // is a haze over the picture rather than part of it. The curve on the
        // rest keeps the middle from filling the window.
        final above = ((value - 0.18) / 0.82).clamp(0.0, 1.0);
        final loudness = math.pow(above, 1.5).toDouble().clamp(0.0, 1.0);
        final colour = _heat(loudness);
        // **Opaque, and multiplied through.** Two mistakes were made here in
        // one line: laid on as a wash the picture had no ground of its own, so
        // quiet came out as dirty paper rather than as clean page; and these
        // bytes are read as premultiplied, so a translucent pixel that still
        // carried its colour was *added* to the page.
        pixels[at] = (colour.r * 255).round();
        pixels[at + 1] = (colour.g * 255).round();
        pixels[at + 2] = (colour.b * 255).round();
        pixels[at + 3] = 255;
      }
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      columns,
      bands,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  /// A hundredth of a second each, up to a ceiling.
  ///
  /// Fine rather than one per pixel because the same sweep answers two
  /// questions — what the file looks like, and how loud it is right now — and
  /// the second one needs a hundredth of a second to look alive. An hour of
  /// audio hits the ceiling and gets coarser buckets, which no eye can tell at
  /// that length anyway.
  static int _bucketsFor(Duration duration) {
    final tenths = (duration.inMilliseconds / 10).round();
    return tenths.clamp(200, 120000);
  }

  void _fadeShapeIn() {
    final length = motionOf(context, kWaveformArriveDuration);
    if (length == Duration.zero) {
      setState(() => _arrived = 1);
      return;
    }
    _arrivedFrom = _clock.isActive ? _elapsed : Duration.zero;
    _arrivedOver = length;
    _arrived = 0;
    _keepTicking();
  }

  Duration _arrivedFrom = Duration.zero;
  Duration _arrivedOver = Duration.zero;
  Duration _elapsed = Duration.zero;

  // MARK: the clock

  void _onTick(AudioTick tick) {
    // The platform's clock has moved, so the local one may run again. Only ever
    // turned on here: what turns it off is asking for the sound to be somewhere
    // else, which is play and seek.
    if (tick.position > _said) _moving = true;
    _said = tick.position;
    _reported = tick.position;
    _since
      ..reset()
      ..start();
    final playing = tick.playing;
    final ended = tick.ended;
    if (playing != _playing || ended != _ended) {
      setState(() {
        _playing = playing;
        _ended = ended;
      });
    }
    _keepTicking();
  }

  /// The frame loop runs while there is anything left to move: the playhead,
  /// the level falling away, the shape arriving. Otherwise it is stopped —
  /// a viewer holding a paused file must not be repainting sixty times a
  /// second.
  void _keepTicking() {
    final wanted = _playing || _level > 0.001 || _arrived < 1;
    if (wanted && !_clock.isActive) {
      _clock.start();
    } else if (!wanted && _clock.isActive) {
      _clock.stop();
    }
  }

  void _onFrame(Duration elapsed) {
    final step = elapsed - _elapsed;
    _elapsed = elapsed;

    if (_arrived < 1 && _arrivedOver > Duration.zero) {
      final over = (elapsed - _arrivedFrom).inMicroseconds /
          _arrivedOver.inMicroseconds;
      _arrived = over.clamp(0.0, 1.0);
    }

    // How loud the file is where the playhead is standing, with a follower on
    // it: quick to rise, slow to fall, which is how loudness is heard.
    final target = _playing ? _levelAt(_position) : 0.0;
    final rise = step.inMicroseconds / 60000.0;
    final fall = step.inMicroseconds / 260000.0;
    _level = target > _level
        ? math.min(target, _level + rise * (target - _level + 0.6))
        : math.max(target, _level - fall * (_level - target + 0.4));

    setState(() {});
    _keepTicking();
  }

  /// Where the sound is: what the platform last said, plus the time since.
  Duration get _position {
    final duration = _track?.duration ?? Duration.zero;
    if (_ended) return duration;
    final at =
        _playing && _moving ? _reported + _since.elapsed : _reported;
    return at > duration ? duration : at;
  }

  double _levelAt(Duration at) {
    final shape = _shape;
    final total = _track?.duration ?? Duration.zero;
    if (shape == null || total == Duration.zero) return 0;
    final buckets = shape.length ~/ 2;
    final index = (at.inMilliseconds / total.inMilliseconds * buckets)
        .floor()
        .clamp(0, buckets - 1);
    // The average rather than the peak: a peak is one sample and it makes the
    // drawing twitch, an average over a hundredth of a second is a loudness.
    // On the same scale the bars are drawn on, or a quiet file would draw tall
    // bars that never move.
    return (shape[index * 2 + 1] * _gain).clamp(0.0, 1.0);
  }

  // MARK: the controls

  Future<void> _play() async {
    await _sound.play();
    if (!mounted) return;
    setState(() {
      _playing = true;
      _ended = false;
    });
    // Asked for, not started: the playhead waits here until the platform's own
    // clock says the sound is running. See [_moving].
    _moving = false;
    _said = _reported;
    _since
      ..reset()
      ..start();
    _keepTicking();
  }

  Future<void> _pause() async {
    await _sound.pause();
    if (!mounted) return;
    setState(() => _playing = false);
  }

  void _toggle() => unawaited(_playing ? _pause() : _play());

  Future<void> _seekTo(Duration where) async {
    final duration = _track?.duration ?? Duration.zero;
    final at = where < Duration.zero
        ? Duration.zero
        : (where > duration ? duration : where);
    _reported = at;
    // The same rule as play: the drawing stands where it was put until the
    // platform is heard from, rather than running on from a place the sound has
    // not reached yet.
    _moving = false;
    _said = at;
    _since
      ..reset()
      ..start();
    setState(() => _ended = false);
    await _sound.seek(at);
  }

  void _seekBy(Duration step) => unawaited(_seekTo(_position + step));

  /// Which way the file is looked at. Remembered, because it is a property of
  /// the reader rather than of the file in front of them.
  void _showSpectrum(bool spectrum) {
    if (_spectrum == spectrum) return;
    setState(() => _spectrum = spectrum);
    unawaited(_settings.setSoundSpectrum(spectrum));
    if (spectrum) unawaited(_askForSpectrum());
  }

  Future<void> _setVolume(double value) async {
    final level = value.clamp(0.0, 1.0);
    setState(() => _volume = level);
    await _sound.setVolume(level);
    // Kept for the next file and the next run: turning it down for one track
    // and finding the next at full scale is the one thing a player must not do.
    await _settings.setSoundVolume(level);
  }

  // MARK: the keys

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final coarse = keys.isControlPressed || keys.isMetaPressed;
    final fine = keys.isShiftPressed;
    final step = Duration(seconds: coarse ? 30 : (fine ? 1 : 5));

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _toggle();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekBy(-step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(step);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _volumeDragged = false;
        unawaited(_setVolume(_volume + 0.05));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _volumeDragged = false;
        unawaited(_setVolume(_volume - 0.05));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyW:
        _showSpectrum(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        _showSpectrum(true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        unawaited(_seekTo(Duration.zero));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        unawaited(_seekTo(_track?.duration ?? Duration.zero));
        return KeyEventResult.handled;
    }

    // The ten digits jump through the file in tenths, which is the one gesture
    // every player on the machine already has.
    final digit = _digitOf(event.logicalKey);
    if (digit != null) {
      final total = _track?.duration ?? Duration.zero;
      unawaited(_seekTo(total * (digit / 10)));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static int? _digitOf(LogicalKeyboardKey key) {
    const digits = [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final index = digits.indexOf(key);
    return index < 0 ? null : index;
  }

  // MARK: the drawing

  @override
  Widget build(BuildContext context) {
    final trouble = _trouble;
    if (trouble != null) return _Trouble(message: trouble);

    final track = _track;
    if (track == null) return const SizedBox.expand();

    final colours = readingColours(context);
    return Focus(
      focusNode: _keys,
      canRequestFocus: widget.hasKeyboard,
      onKeyEvent: _onKey,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _waveform(track, colours)),
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _switches(),
                  ),
                ),
              ],
            ),
          ),
          _below(track, colours),
        ],
      ),
    );
  }

  Widget _waveform(AudioTrack track, ReadingColours colours) => LayoutBuilder(
        builder: (context, box) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // A press is a seek and a drag is a scrub — the shape is the only
            // slider this viewer has, because a second one under it would be a
            // control saying what the drawing already says.
            onTapDown: (at) => _seekAcross(at.localPosition.dx, box.maxWidth),
            onHorizontalDragUpdate: (at) =>
                _seekAcross(at.localPosition.dx, box.maxWidth),
            child: CustomPaint(
              painter: _WavePainter(
                picture: _spectrum ? _picture : null,
                shape: _shape,
                gain: _gain,
                arrived: _arrived,
                played: track.duration == Duration.zero
                    ? 0
                    : _position.inMilliseconds / track.duration.inMilliseconds,
                level: _level,
                ink: colours.ink,
                accent: colours.accent,
                minuteMarks: track.duration.inSeconds >= 120,
                seconds: track.duration.inSeconds.toDouble(),
              ),
            ),
          ),
        ),
      );

  void _seekAcross(double x, double width) {
    final duration = _track?.duration ?? Duration.zero;
    if (width <= 0 || duration == Duration.zero) return;
    unawaited(_seekTo(duration * (x / width).clamp(0.0, 1.0)));
  }

  Widget _switches() => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ViewportChrome(
            children: [
              ViewportSwitch(
                icon: _playing ? Icons.pause : Icons.play_arrow,
                message:
                    '${_playing ? tr('Pause') : tr('Play')}  ${tr('Space')}',
                on: _playing,
                onPressed: _toggle,
              ),
              const ViewportRule(),
              ViewportSwitch(
                icon: Icons.graphic_eq,
                message: '${tr('How loud, over the file')}  W',
                on: !_spectrum,
                onPressed: () => _showSpectrum(false),
              ),
              ViewportSwitch(
                icon: Icons.blur_linear,
                message: '${tr('Which frequencies, over the file')}  S',
                on: _spectrum,
                onPressed: () => _showSpectrum(true),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _VolumeSelector(
            volume: _volume,
            onChanged: (value, {required bool dragged}) {
              _volumeDragged = dragged;
              unawaited(_setVolume(value));
            },
            dragged: _volumeDragged,
          ),
        ],
      );

  /// The times either side of the shape, and everything the decoder said about
  /// the file under them.
  Widget _below(AudioTrack track, ReadingColours colours) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _clockText(_position),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colours.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  _clockText(track.duration),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colours.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _facts(track),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colours.muted),
            ),
          ],
        ),
      );

  /// Everything the machine's own decoder was willing to say, in one line.
  ///
  /// **Nothing here is worked out from the bytes.** What a file's tags say it
  /// is called and who played it are a different question, answered by a plugin
  /// that reads the format — this is the stream as whatever is making the sound
  /// understands it.
  String _facts(AudioTrack track) {
    final parts = <String>[
      if (track.codec.isNotEmpty) track.codec.toUpperCase(),
      if (track.sampleRate > 0)
        '${(track.sampleRate / 1000).toStringAsFixed(1)} ${tr('kHz')}',
      switch (track.channels) {
        0 => '',
        1 => tr('mono'),
        2 => tr('stereo'),
        final many => '$many ${tr('channels')}',
      },
      if (track.bits > 0) '${track.bits} ${tr('bit')}',
      if (track.bitrate > 0) '${(track.bitrate / 1000).round()} ${tr('kbps')}',
      if (track.bytes > 0) formatSize(track.bytes),
      _peakText(),
      '${tr('Volume')} ${(_volume * 100).round()}%',
    ];
    return parts.where((part) => part.isNotEmpty).join('  ·  ');
  }

  /// How loud the file itself is, which is the number the drawing gave up
  /// saying when it normalised itself. Decibels below full scale, the way every
  /// meter that has ever been built says it.
  String _peakText() {
    if (_shape == null) return '';
    if (_peak <= 0.0005) return tr('silence');
    final decibels = 20 * (math.log(_peak) / math.ln10);
    return '${tr('peak')} ${decibels.round()} ${tr('dB')}';
  }

  static String _clockText(Duration at) {
    final hours = at.inHours;
    final minutes = at.inMinutes.remainder(60);
    final seconds = at.inSeconds.remainder(60);
    final tail = '${minutes.toString().padLeft(hours > 0 ? 2 : 1, '0')}'
        ':${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '$hours:$tail' : tail;
  }
}

/// The shape of the file, and where in it the sound has got to.
///
/// Bars rather than a filled outline: a bar is what a hundredth of a second
/// looks like, and the gaps between them are what stop a long file from turning
/// into a solid block. Two heights on each — the peak behind, faint, and the
/// average in front — because a waveform drawn from peaks alone is a hedge and
/// one drawn from averages alone is a worm.
class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.picture,
    required this.shape,
    required this.gain,
    required this.arrived,
    required this.played,
    required this.level,
    required this.ink,
    required this.accent,
    required this.minuteMarks,
    required this.seconds,
  });

  /// The file as frequencies, or null where the shape is what is being looked
  /// at — or where it has been asked for and has not arrived, which is why the
  /// shape goes on being drawn until it does rather than the window emptying.
  final ui.Image? picture;

  final Float32List? shape;

  /// What the samples are multiplied by so the file's loudest moment reaches
  /// the top of the window. See [_AudioViewState._peak].
  final double gain;

  /// How much of the drawing has appeared, 0..1.
  final double arrived;

  /// How far through the file the playhead is, 0..1.
  final double played;

  /// How loud it is at the playhead, 0..1.
  final double level;

  final Color ink;
  final Color accent;
  final bool minuteMarks;
  final double seconds;

  /// Logical pixels a bar takes, including the gap after it.
  static const double _pitch = 3;
  static const double _bar = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final middle = size.height / 2;
    // **Six tenths of the height.** There is no sense in the whole of it —
    // there is text below and buttons above either way. Half of that either
    // side of the middle line, which also leaves the lift near the playhead
    // somewhere to go: a shape already at the
    // ceiling cannot breathe, and it is loudest exactly where it would.
    final room = size.height * 0.30;
    if (room <= 0 || size.width <= 0) return;

    final frequencies = picture;
    if (frequencies != null) {
      _paintSpectrum(canvas, size, frequencies);
      _paintPlayhead(canvas, size, size.width * played.clamp(0.0, 1.0),
          onThermal: true);
      return;
    }

    _paintMinutes(canvas, size);

    // The line the sound sits on, so an empty file and a silent passage still
    // look like a sound rather than like nothing being drawn.
    canvas.drawRect(
      Rect.fromLTWH(0, middle - 0.5, size.width, 1),
      Paint()..color = ink.withValues(alpha: 0.12),
    );

    final data = shape;
    if (data == null) return;

    final buckets = data.length ~/ 2;
    final bars = math.max(1, (size.width / _pitch).floor());
    final playedTo = size.width * played.clamp(0.0, 1.0);

    // **Looked at rather than reasoned about.** The first weights had the
    // unplayed part at 0.22 and 0.42 of the ink, and on a rendered page it was
    // barely there — a file looked half drawn rather than half played. What
    // separates the two halves is the colour; it does not also need most of the
    // contrast.
    final quietPeak = Paint()..color = ink.withValues(alpha: 0.34 * arrived);
    final quietBody = Paint()..color = ink.withValues(alpha: 0.64 * arrived);
    final loudPeak = Paint()..color = accent.withValues(alpha: 0.50 * arrived);
    final loudBody = Paint()..color = accent.withValues(alpha: 0.95 * arrived);

    for (var bar = 0; bar < bars; bar++) {
      final from = (bar * buckets / bars).floor();
      final to = math.max(from + 1, ((bar + 1) * buckets / bars).floor());
      var peak = 0.0;
      var body = 0.0;
      for (var i = from; i < to && i < buckets; i++) {
        peak = math.max(peak, data[i * 2]);
        body += data[i * 2 + 1];
      }
      body /= to - from;
      peak = math.min(1, peak * gain);
      body = math.min(1, body * gain);

      final x = bar * _pitch;
      // **The one thing that moves with the music.** Bars within a few pixels
      // of the playhead are lifted by how loud it is right now — which is a
      // fact about this instant, where the shape itself is a fact about the
      // file. Everything else stands still — **at its own height, not at
      // none**: the first version of this line multiplied the far bars by zero
      // instead of by one, and the whole file collapsed to a one-pixel rule
      // with a hump travelling along it. It looked like a viewer that only
      // draws a second either side of the playhead, and it took looking at the
      // screen to see it.
      final near = 1 - ((x + _bar / 2) - playedTo).abs() / 90;
      final lift = near <= 0 ? 1.0 : 1 + 0.22 * level * near * near;

      // The ceiling is what the lift may reach, not what the shape draws to.
      final ceiling = size.height / 2 - 6;
      final tall = (peak * room * arrived * lift).clamp(1.0, ceiling);
      final short = (body * room * arrived * lift).clamp(1.0, ceiling);
      final loud = x + _bar / 2 <= playedTo;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x, middle - tall, x + _bar, middle + tall),
          const Radius.circular(1),
        ),
        loud ? loudPeak : quietPeak,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x, middle - short, x + _bar, middle + short),
          const Radius.circular(1),
        ),
        loud ? loudBody : quietBody,
      );
    }

    _paintPlayhead(canvas, size, playedTo);
  }

  /// The frequencies, across the whole of the window it is given.
  ///
  /// **Edge to edge, on its own ground**, rather than sitting in a band with
  /// the page around it. A spectrum drawn on a light page is a picture with a
  /// hole cut in it; drawn on the black at the
  /// bottom of its own scale it is what a spectrogram has always looked like,
  /// and quiet reads as quiet rather than as an empty rectangle. The shape
  /// keeps its six tenths — that is a drawing *on* the page and this is not.
  ///
  /// The part that has not played yet is veiled rather than drawn faintly: on a
  /// scale whose bottom is black, less light *is* the thing to say.
  void _paintSpectrum(Canvas canvas, Size size, ui.Image image) {
    final everything = Offset.zero & size;
    canvas.drawRect(
      everything,
      Paint()..color = _thermalGround.withValues(alpha: arrived),
    );

    final from = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      from,
      everything,
      Paint()
        // Sharp rather than smoothed: at one band per two pixels there is
        // something to see, and smoothing it is what turned the first version
        // into a haze.
        ..filterQuality = FilterQuality.low
        ..color = Color.fromRGBO(0, 0, 0, arrived),
    );

    final playedTo = size.width * played.clamp(0.0, 1.0);
    canvas.drawRect(
      Rect.fromLTRB(playedTo, 0, size.width, size.height),
      Paint()..color = const Color(0xFF05010A).withValues(alpha: 0.45 * arrived),
    );
  }

  /// A minute at a time, faintly, so a long file can be aimed at rather than
  /// guessed at. Only where a file is long enough for the marks to mean
  /// something.
  void _paintMinutes(Canvas canvas, Size size) {
    if (!minuteMarks || seconds <= 0) return;
    final paint = Paint()..color = ink.withValues(alpha: 0.07);
    // A mark a minute while they stay apart; then five, then ten — the marks
    // are for aiming with and a picket fence is no use for that.
    final every = seconds > 3600 ? 600.0 : (seconds > 900 ? 300.0 : 60.0);
    for (var at = every; at < seconds; at += every) {
      final x = size.width * at / seconds;
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), paint);
    }
  }

  void _paintPlayhead(Canvas canvas, Size size, double x,
      {bool onThermal = false}) {
    // On the thermal ground the accent is one of the scale's own colours, so
    // the line that says where you are would be a line the picture could have
    // drawn itself. White is nothing on that scale but the top of it.
    final mark = onThermal ? const Color(0xFFFFFFFF) : accent;
    // The glow answers to the level, so the playhead brightens with the music
    // rather than sliding along at a fixed weight.
    if (level > 0.01) {
      canvas.drawRect(
        Rect.fromLTWH(x - 9, 0, 18, size.height),
        Paint()
          ..color = mark.withValues(alpha: 0.16 * level)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 8 * level),
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(x - 1, 0, 2, size.height),
      Paint()..color = mark.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.picture != picture ||
      old.shape != shape ||
      old.gain != gain ||
      old.arrived != arrived ||
      old.played != played ||
      old.level != level ||
      old.ink != ink ||
      old.accent != accent;
}

/// The volume, as a column you set rather than two buttons you press.
///
/// A column is the right shape for it — loudness is one quantity with a top
/// and a bottom, so the control should show where in that it stands, which a
/// pair of steps never can.
///
/// It stands under the play switch in the same quiet surface the other viewport
/// controls use, because what is behind it is somebody else's file.
class _VolumeSelector extends StatelessWidget {
  const _VolumeSelector({
    required this.volume,
    required this.onChanged,
    required this.dragged,
  });

  final double volume;

  /// [dragged] says where the change came from: a hand on the track, or a key
  /// or the wheel. The first must not animate — see [kVolumeGlideDuration].
  final void Function(double volume, {required bool dragged}) onChanged;
  final bool dragged;

  static const double _height = 92;
  static const double _width = 26;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The whole column is the scale, so a press at the top is full and a press
    // at the bottom is silence — nothing to aim at but the height.
    void setFrom(Offset at) {
      final value = 1 - (at.dy / _height);
      onChanged(value.clamp(0.0, 1.0), dragged: true);
    }

    return Hint(
      message: '${tr('Volume')} ${(volume * 100).round()}%  ↑↓',
      child: ViewportChrome(
        children: [
          Listener(
            // A wheel over it is a step, not a drag: it arrives in notches and
            // there is no finger to follow.
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) {
                onChanged(
                  (volume - signal.scrollDelta.dy / 600).clamp(0.0, 1.0),
                  dragged: false,
                );
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (at) => setFrom(at.localPosition),
              onVerticalDragUpdate: (at) => setFrom(at.localPosition),
              child: SizedBox(
                width: _width,
                height: _height,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      volume < 0.005
                          ? Icons.volume_off
                          : (volume < 0.5
                              ? Icons.volume_down
                              : Icons.volume_up),
                      size: 13,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.55),
                    ),
                    const SizedBox(height: 5),
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: LayoutBuilder(
                          // Wide enough for the knob, not for the track: a
                          // `Stack` clips to the size of its largest child, and
                          // a knob laid over a four-pixel bar was quietly cut
                          // down to four pixels of itself.
                          builder: (context, box) => SizedBox(
                            width: 14,
                            height: box.maxHeight,
                            child: Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              Container(
                                width: 4,
                                height: box.maxHeight,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              AnimatedContainer(
                                duration: dragged
                                    ? Duration.zero
                                    : motionOf(context, kVolumeGlideDuration),
                                curve: Curves.easeOut,
                                width: 4,
                                height: box.maxHeight * volume,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              AnimatedPositioned(
                                duration: dragged
                                    ? Duration.zero
                                    : motionOf(context, kVolumeGlideDuration),
                                curve: Curves.easeOut,
                                bottom: (box.maxHeight * volume) - 6,
                                // A knob of its own colour, not more of the
                                // fill: drawn in the accent it disappeared into
                                // the bar it was supposed to mark the top of,
                                // which magnifying the picture showed at once.
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.colorScheme.primary,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Trouble extends StatelessWidget {
  const _Trouble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.music_off_outlined, size: 32),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

/// The colour a cell of the spectrum is, quiet to loud.
///
/// **A thermal scale, and deliberately not the page's own colours.** Two goes
/// at painting a spectrum in the accent had shown why — a scale built out of
/// one hue has only alpha to say loudness with, and alpha over paper is a
/// wash.
/// This is the scale every spectrogram has been printed in since they were
/// printed on paper: black through indigo and magenta into red, orange and
/// yellow, and white where it is loudest. It changes hue *and* lightness at
/// every step, which is what makes a value readable off it by eye.
///
/// It also means the picture brings its own ground: the quiet parts are the
/// black at the bottom of the scale rather than whatever the page is, so a
/// spectrum looks the same on a light reading and a dark one — which is right,
/// because what it shows is the file and not the page.
/// The bottom of [_thermal] — what a spectrum's silence is, and the ground it
/// is drawn on.
const Color _thermalGround = Color(0xFF05010A);

const List<Color> _thermal = [
  Color(0xFF05010A),
  Color(0xFF1B0B3B),
  Color(0xFF4B1178),
  Color(0xFF8C1D6E),
  Color(0xFFC33B36),
  Color(0xFFEE7B14),
  Color(0xFFF7CB44),
  Color(0xFFFFF6D5),
];

Color _heat(double loudness) {
  final at = (loudness.clamp(0.0, 1.0)) * (_thermal.length - 1);
  final low = at.floor().clamp(0, _thermal.length - 1);
  final high = (low + 1).clamp(0, _thermal.length - 1);
  return Color.lerp(_thermal[low], _thermal[high], at - low)!;
}
