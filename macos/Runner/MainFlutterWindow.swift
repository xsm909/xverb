import AVFoundation
import Accelerate
import AudioToolbox
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSDraggingDestination, NSWindowDelegate {
  /// The engine every window of the application draws into.
  ///
  /// **Made here rather than by the view controller**, and the order below is
  /// the whole reason. A `FlutterViewController()` with no engine makes one of
  /// its own and owns that engine's single implicit view; an engine like that
  /// refuses every window after the first — *"Multiview can only be enabled
  /// before adding any view controllers"* — and several windows on one engine
  /// is the whole of detaching a view, because a second engine is a second
  /// isolate and none of the state would cross it.
  ///
  /// So: the engine first, run before any view exists (a view cannot be added
  /// to an engine that is not running), then the controller on it, then the
  /// window, then the plugins — with no return to the run loop in between, so
  /// Dart's first platform message finds the window and the plugins already
  /// there.
  private(set) var engine: FlutterEngine!

  override func awakeFromNib() {
    let engine = FlutterEngine(
      name: "xverb", project: nil, allowHeadlessExecution: true)
    self.engine = engine

    // **Several views on one engine, switched on before any of them exists.**
    // The selector is not in the public header — this is the experimental
    // side of Flutter, leaned on deliberately — and the engine refuses the
    // call once a view controller has been attached, which is why it is here
    // and not three lines down. Without it the first detached window throws
    // "Multiview can only be enabled before adding any view controllers".
    let enableMultiView = Selector(("enableMultiView"))
    if engine.responds(to: enableMultiView) {
      engine.perform(enableMultiView)
    } else {
      NSLog("xverb: this engine has no enableMultiView; one window only")
    }

    _ = engine.run(withEntrypoint: nil)

    let flutterViewController = FlutterViewController(
      engine: engine, nibName: nil, bundle: nil)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    BackdropChannel.register(with: flutterViewController)
    ShellChannel.register(with: flutterViewController)
    AudioChannel.register(with: flutterViewController)
    TransferChannel.register(with: flutterViewController)

    // The window takes the drops rather than a view of ours taking them.
    //
    // A view registered for dragged types has to sit somewhere in the
    // hierarchy, and the only place with a view of ours over the whole window
    // is on top of Flutter's — where it would have to be talked out of eating
    // every click. The window is behind all of it, is asked when no view
    // claims the drag, and is a place a file manager's drop belongs anyway:
    // what receives the files is the application, not a rectangle in it.
    //
    // Flutter's own view is asked to stop claiming drags first. AppKit offers a
    // drag to the view under the pointer before it offers it to the window, so
    // a view that has registered for a type — whether or not it does anything
    // with it — is a view the window never hears past.
    flutterViewController.view.unregisterDraggedTypes()
    registerForDraggedTypes([.fileURL])

    // **The window is the application's own from here on**, and this side is
    // what makes it so: no bar of the platform's, hidden until there is
    // something painted to put in it, glass when the appearance asks for it,
    // and the three buttons answered where the `NSWindow` is in hand. See
    // [WindowChannel] for why none of that can be left to a plugin.
    WindowChannel.attach(window: self, engine: engine)

    // **The delegate is the window itself.** A window hands its dragging
    // messages to its delegate when the delegate answers them and to itself
    // otherwise, so a separate delegate object would have quietly taken the
    // drops away from the methods below. Everything the delegate hears is
    // handed straight to [WindowChannel].
    self.delegate = self

    super.awakeFromNib()
  }

  // --- What the window does on its own, told to Dart ------------------------

  /// **Closing is an ask, not an act.** The application has the folder
  /// history, the plugin processes and the settings to write down, so Dart is
  /// told and the window stays; whoever answers calls `destroy` when it is
  /// done. This covers the platform's own ways out — Cmd+W, the menu — as
  /// well as our own button, which goes through the same place.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    WindowChannel.closing(sender)
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) {
    WindowChannel.front(self, true)
  }

  func windowDidResignKey(_ notification: Notification) {
    WindowChannel.front(self, false)
  }

  /// The shape is reported rather than the event: "something changed" is not
  /// enough to know whether the window now fills the screen, and a restore
  /// can land on either shape depending on what the window was before.
  func windowDidResize(_ notification: Notification) {
    WindowChannel.shapeChanged(self)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    WindowChannel.shapeChanged(self)
  }

  // --- Files arriving from the desktop --------------------------------------
  //
  // Every one of these hands the question to Dart and answers with what Dart
  // last said. See [TransferChannel] for why that is a frame behind and why
  // that is the right trade.

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return TransferChannel.answer(for: sender)
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return TransferChannel.answer(for: sender)
  }

  func draggingExited(_ sender: NSDraggingInfo?) {
    TransferChannel.left()
  }

  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return true
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return TransferChannel.drop(sender)
  }
}

/// The `xverb/backdrop` channel, macOS side: **how far a window not in front
/// steps back**, and how long it takes to get there.
///
/// The rest of that channel is the Windows runner's — the composition accent
/// behind a frameless window, which has no counterpart here, since the Mac's
/// backdrop is `flutter_acrylic`'s business. So this answers the one call the
/// two platforms share and reports the others as not implemented; the Dart
/// side only sends that one, behind `BackdropChannel.fadesWholeWindow`.
///
/// **The window and the drawing on it fade by different figures**, and the two
/// multiply. The window's `alphaValue` carries the glass, the edge and the
/// shadow; the Flutter view's carries the interface, on top of that, and the
/// pair ends at what the setting asks for. One figure over everything is what
/// was tried first and it looks wrong: the glass is a blur of the desktop, and
/// thinning it lets the desktop through *sharp*, so the background reads as
/// fading harder than the content. The arithmetic behind the pair is Dart's —
/// `kWindowShareOfTheFade` in `core/settings/appearance_settings.dart`.
///
/// **The Flutter view is a subview, not the content view.** `flutter_acrylic`
/// hands the window to `macos_window_utils`, which makes the content view an
/// `NSVisualEffectView` — the glass — and puts the Flutter view inside it, as
/// the view of a child controller of its own. So `contentViewController` is no
/// longer a `FlutterViewController` once the backdrop is up, and a guard that
/// asked for one found no window of the program's to fade and did nothing at
/// all, silently. See [flutterView].
///
/// Written in this file for the reason [ShellChannel] gives: a new file means
/// editing the Xcode project.
enum BackdropChannel {
  /// How see-through a window not in front is, 1 for not at all, in the two
  /// layers it is made of — the window itself and the drawing on it — and how
  /// long it takes to get there. All three are the appearance settings',
  /// resent whenever they change, and held here because a window made later
  /// has to be given them too.
  private static var inactiveGlass: CGFloat = 1
  private static var inactiveDrawing: CGFloat = 1
  private static var fade: TimeInterval = 0.24

  /// Whether the front is already being watched, so a second engine — a
  /// second view of the same program — does not add the observers twice and
  /// fade everything twice over.
  private static var watching = false

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "xverb/backdrop",
      binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "inactiveOpacity":
        let args = call.arguments as? [String: Any] ?? [:]
        func figure(_ key: String) -> CGFloat {
          CGFloat(min(max((args[key] as? NSNumber)?.doubleValue ?? 1, 0.1), 1))
        }
        inactiveGlass = figure("value")
        inactiveDrawing = figure("content")
        if let ms = (args["ms"] as? NSNumber)?.doubleValue, ms >= 0 {
          fade = ms / 1000
        }
        // Whatever is already behind another window goes to the new figure at
        // once, with the same fade, so the slider can be seen doing something
        // while it is being dragged rather than only the next time the window
        // loses the keyboard.
        for window in NSApp.windows { fadeToWhereItBelongs(window) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    watchTheFront()
  }

  /// **The fade hangs on the notifications, not on the window's own
  /// `becomeKey`.** `object: nil` hears about every window the program has,
  /// including any it makes later, and the window class itself then has
  /// nothing to carry.
  private static func watchTheFront() {
    if watching { return }
    watching = true
    for name in [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ] {
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { note in
        guard let window = note.object as? NSWindow else { return }
        fadeToWhereItBelongs(window)
      }
    }
  }

  /// Fades [window] to full strength or to the inactive figures, by where it
  /// stands now. Windows that are not the program's own are left alone.
  private static func fadeToWhereItBelongs(_ window: NSWindow) {
    guard let drawing = flutterView(in: window) else { return }
    let behind: CGFloat = window.isKeyWindow ? 1 : inactiveGlass
    let front: CGFloat = window.isKeyWindow ? 1 : inactiveDrawing
    if abs(window.alphaValue - behind) < 0.001,
      abs(drawing.alphaValue - front) < 0.001
    { return }
    drawing.wantsLayer = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fade
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = behind
      drawing.animator().alphaValue = front
    }
  }

  /// **The view the program draws into**, or nil for a window that is not the
  /// program's.
  ///
  /// Both arrangements are answered: the plain one, where the Flutter
  /// controller is the window's own, and the one `macos_window_utils` leaves
  /// behind once the backdrop is up, where the content view is the glass and
  /// the Flutter controller is a child of its controller. Asking for the glass
  /// by class would tie this to that package; asking for the Flutter
  /// controller does not.
  private static func flutterView(in window: NSWindow) -> NSView? {
    guard let root = window.contentViewController else { return nil }
    if let flutter = root as? FlutterViewController { return flutter.view }
    for child in root.children {
      if let flutter = child as? FlutterViewController { return flutter.view }
    }
    return nil
  }
}

/// The `xverb/shell` channel, macOS side.
///
/// The same channel name the Windows runner uses for the desktop's own context
/// menu. Only the icons are answered here; anything else this build has not
/// been taught is reported as not implemented, which is what the Dart side
/// treats as "this desktop cannot do that".
///
/// Written in this file rather than one of its own on purpose: a new file means
/// editing the Xcode project, and everything here is forty lines.
enum ShellChannel {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "xverb/shell",
      binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "fileIcon":
        result(fileIcon(arguments: call.arguments))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The icon for a kind of file, as PNG bytes.
  ///
  /// `byPath` asks about one particular file — a bundle carries its own
  /// picture — and costs a disk touch. Everything else is asked by extension,
  /// so a listing costs one lookup per kind rather than one per row.
  ///
  /// `icon(forFileType:)` is deprecated in favour of `icon(for: UTType)`, which
  /// needs macOS 11; this target is 10.15, so the older call is the one that
  /// works everywhere the app runs.
  private static func fileIcon(arguments: Any?) -> Any? {
    guard let args = arguments as? [String: Any],
          let path = args["path"] as? String
    else { return nil }

    let byPath = args["byPath"] as? Bool ?? false
    let isDirectory = args["isDirectory"] as? Bool ?? false
    let pixels = args["pixels"] as? Int ?? 32

    let image: NSImage
    if byPath {
      image = NSWorkspace.shared.icon(forFile: path)
    } else if isDirectory {
      image = NSWorkspace.shared.icon(forFileType: "public.folder")
    } else {
      let ext = (path as NSString).pathExtension
      image = NSWorkspace.shared.icon(
        forFileType: ext.isEmpty ? "public.data" : ext)
    }

    guard let png = pngData(from: image, pixels: pixels) else { return nil }
    return FlutterStandardTypedData(bytes: png)
  }

  /// Draws [image] into a bitmap of exactly [pixels] square and encodes it.
  ///
  /// An `NSImage` holds several representations at several sizes and no pixels
  /// of its own, so it is drawn rather than asked for its data: asking would
  /// give whichever representation it felt like, at whichever size that is.
  private static func pngData(from image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
      in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
      from: .zero,
      operation: .sourceOver,
      fraction: 1)

    return rep.representation(using: .png, properties: [:])
  }
}

/// The `xverb/audio` channel, macOS side.
///
/// **The engine plays the file; this asks it to.** `AVAudioPlayer` is the
/// machine's own player, so what can be played is whatever this machine reads
/// — measured here before a line was written: wav at 16, 24 and float bits,
/// aiff, caf, mp3, m4a as both AAC and ALAC, and flac. Nothing about those
/// formats is known here, which is the point.
///
/// In this file rather than one of its own for the reason `ShellChannel` gives:
/// a new file means editing the Xcode project.
enum AudioChannel {
  static func register(with controller: FlutterViewController) {
    let messenger = controller.engine.binaryMessenger
    let player = AudioPlayerBox()

    let channel = FlutterMethodChannel(name: "xverb/audio",
                                       binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "open":
        guard let path = args["path"] as? String else { return result(nil) }
        result(player.open(path: path))
      case "play":
        player.play()
        result(nil)
      case "pause":
        player.pause()
        result(nil)
      case "seek":
        player.seek(ms: args["positionMs"] as? Int ?? 0)
        result(nil)
      case "volume":
        player.setVolume(args["volume"] as? Double ?? 1)
        result(nil)
      case "close":
        player.close()
        result(nil)
      case "envelope":
        guard let path = args["path"] as? String else { return result(nil) }
        let buckets = args["buckets"] as? Int ?? 800
        // Off the main thread: a ten-minute AAC is 388 ms of decoding, and the
        // window must not stop for it. The answer goes back on the main thread
        // because a channel result must.
        DispatchQueue.global(qos: .userInitiated).async {
          let shape = AudioPlayerBox.envelope(path: path, buckets: buckets)
          DispatchQueue.main.async { result(shape) }
        }
      case "spectrum":
        guard let path = args["path"] as? String else { return result(nil) }
        let columns = args["columns"] as? Int ?? 1024
        let bands = args["bands"] as? Int ?? 48
        DispatchQueue.global(qos: .userInitiated).async {
          let picture = AudioPlayerBox.spectrum(
            path: path, columns: columns, bands: bands)
          DispatchQueue.main.async { result(picture) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterEventChannel(name: "xverb/audio/ticks",
                        binaryMessenger: messenger)
      .setStreamHandler(player)
  }
}

/// One player, one file. A second `open` closes the first: two sounds at once
/// out of a file manager is a defect however it comes about.
final class AudioPlayerBox: NSObject, FlutterStreamHandler, AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var sink: FlutterEventSink?
  private var ticker: Timer?
  private var volume: Float = 0.7
  private var finished = false

  // MARK: the file

  func open(path: String) -> [String: Any]? {
    close()
    let url = URL(fileURLWithPath: path)
    guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
    player.delegate = self
    player.volume = volume
    player.prepareToPlay()
    self.player = player
    finished = false

    let format = player.format.streamDescription.pointee
    var answer: [String: Any] = [
      "durationMs": Int(player.duration * 1000),
      "sampleRate": format.mSampleRate,
      "channels": Int(format.mChannelsPerFrame),
      "codec": Self.fourCC(format.mFormatID),
      "bits": Int(format.mBitsPerChannel),
    ]
    answer["bitrate"] = Self.bitrate(url: url, duration: player.duration)
    answer["bytes"] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return answer
  }

  func play() {
    guard let player else { return }
    // Playing after the end restarts rather than doing nothing: pressing play
    // on a finished track and getting silence reads as a broken player.
    if finished || player.currentTime >= player.duration {
      player.currentTime = 0
      finished = false
    }
    player.play()
    startTicking()
    sendTick()
  }

  func pause() {
    player?.pause()
    sendTick()
    stopTicking()
  }

  func seek(ms: Int) {
    guard let player else { return }
    let where_ = max(0, min(player.duration, Double(ms) / 1000))
    player.currentTime = where_
    finished = false
    sendTick()
  }

  func setVolume(_ value: Double) {
    volume = Float(max(0, min(1, value)))
    player?.volume = volume
  }

  func close() {
    stopTicking()
    player?.stop()
    player = nil
    finished = false
  }

  // MARK: where it has got to

  private func startTicking() {
    guard ticker == nil else { return }
    // Ten a second: often enough to keep a local clock honest, rare enough to
    // cost nothing. Whoever draws interpolates between two of these.
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.sendTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicking() {
    ticker?.invalidate()
    ticker = nil
  }

  private func sendTick() {
    guard let sink, let player else { return }
    sink([
      "positionMs": Int(player.currentTime * 1000),
      "playing": player.isPlaying,
      "ended": finished,
    ])
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    finished = true
    sendTick()
    stopTicking()
  }

  // MARK: the stream handler

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: the shape of the whole file

  /// [buckets] pairs of peak and average, 0..1, read straight off the samples.
  ///
  /// `AVAudioFile` decodes into float PCM whatever the file was written in, so
  /// the same loop covers mp3, AAC, ALAC, flac and plain wav. Read in blocks
  /// rather than whole: a ten-minute file as 32-bit floats is 200 MB, and none
  /// of it is needed twice.
  static func envelope(path: String, buckets: Int) -> FlutterStandardTypedData? {
    guard buckets > 0,
          let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          file.length > 0
    else { return nil }

    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536)
    else { return nil }

    var shape = [Float](repeating: 0, count: buckets * 2)
    var counts = [Int](repeating: 0, count: buckets)
    let total = Double(file.length)
    var frame = 0.0

    while true {
      do { try file.read(into: buffer) } catch { break }
      let read = Int(buffer.frameLength)
      if read == 0 { break }
      guard let channels = buffer.floatChannelData else { break }
      let channelCount = Int(buffer.format.channelCount)

      for i in 0..<read {
        // The louder of the two channels, not their average: a sound only in
        // the left channel is still a sound, and averaging halves it.
        var value: Float = 0
        for c in 0..<channelCount {
          value = max(value, abs(channels[c][i]))
        }
        let bucket = min(buckets - 1, Int((frame + Double(i)) / total * Double(buckets)))
        shape[bucket * 2] = max(shape[bucket * 2], value)
        shape[bucket * 2 + 1] += value
        counts[bucket] += 1
      }
      frame += Double(read)
    }

    for b in 0..<buckets where counts[b] > 0 {
      shape[b * 2 + 1] /= Float(counts[b])
    }
    let bytes = shape.withUnsafeBufferPointer { Data(buffer: $0) }
    return FlutterStandardTypedData(float32: bytes)
  }

  // MARK: the file seen as frequencies

  /// [columns] slices of time, each [bands] values from low to high, 0..1 off a
  /// decibel scale.
  ///
  /// **Read as a stream, not as an array.** Ten minutes of mono float is 105 MB,
  /// and none of it is wanted twice: samples go into a ring the width of one
  /// window, and every time the playhead of the read crosses the next slice's
  /// boundary that ring is transformed. The transform itself is Accelerate's,
  /// through the C interface rather than the Swift one — this target is 10.15
  /// and `vDSP.FFT` needs 11.
  static func spectrum(path: String, columns: Int, bands: Int) -> FlutterStandardTypedData? {
    guard columns > 0, bands > 0,
          let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          file.length > 0
    else { return nil }

    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536)
    else { return nil }

    // **Two thousand and forty-eight, not a thousand.** At 1024 a bin is 43 Hz
    // wide, so every band below about 400 Hz lands on the same one or two bins
    // and the bottom of the picture comes out as blocks — which is most of what
    // made the first spectrum look like a smear. This is 21 Hz a bin, at 46 ms
    // a slice, which is the usual bargain a spectrogram strikes.
    let size = 2048
    let half = size / 2
    let log2n = vDSP_Length(11)
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    else { return nil }
    defer { vDSP_destroy_fftsetup(setup) }

    // Hann, so a slice does not report the edges of its own window as sound.
    var window = [Float](repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

    var ring = [Float](repeating: 0, count: size)
    var ringAt = 0
    var picture = [Float](repeating: 0, count: columns * bands)

    // Which frequency each band ends at, spaced by ear rather than evenly: the
    // top half of a linear scale is where almost nothing happens, and the
    // bottom sixteenth is where nearly all of music is.
    let rate = Float(format.sampleRate)
    let lowest: Float = 40
    let highest = min(rate / 2, 16000)
    var edges = [Int](repeating: 0, count: bands + 1)
    // And where each band sits in bins as a fraction, for the ones too narrow
    // to contain one.
    var centres = [Double](repeating: 0, count: bands)
    let perBin = rate / Float(size)
    for b in 0...bands {
      let hertz = lowest * pow(highest / lowest, Float(b) / Float(bands))
      edges[b] = min(half - 1, max(1, Int(hertz / perBin)))
      if b < bands {
        let next = lowest * pow(highest / lowest, Float(b + 1) / Float(bands))
        centres[b] = Double(sqrt(hertz * next) / perBin)
      }
    }

    let total = Double(file.length)
    let hop = max(1.0, total / Double(columns))
    var frame = 0.0
    var nextSlice = 0.0
    var slice = 0

    var real = [Float](repeating: 0, count: half)
    var imaginary = [Float](repeating: 0, count: half)
    var magnitudes = [Float](repeating: 0, count: half)
    var windowed = [Float](repeating: 0, count: size)

    while slice < columns {
      do { try file.read(into: buffer) } catch { break }
      let read = Int(buffer.frameLength)
      if read == 0 { break }
      guard let channels = buffer.floatChannelData else { break }
      let channelCount = Int(buffer.format.channelCount)

      for i in 0..<read {
        // Mixed to one: a spectrum of the left channel is not a spectrum of the
        // file, and two of them side by side is a different picture again.
        var value: Float = 0
        for c in 0..<channelCount { value += channels[c][i] }
        ring[ringAt] = value / Float(channelCount)
        ringAt = (ringAt + 1) % size

        if frame >= nextSlice && slice < columns {
          // The ring, oldest first, through the window.
          for k in 0..<size {
            windowed[k] = ring[(ringAt + k) % size] * window[k]
          }
          windowed.withUnsafeMutableBufferPointer { samples in
            real.withUnsafeMutableBufferPointer { realp in
              imaginary.withUnsafeMutableBufferPointer { imagp in
                var split = DSPSplitComplex(realp: realp.baseAddress!,
                                            imagp: imagp.baseAddress!)
                samples.baseAddress!.withMemoryRebound(
                  to: DSPComplex.self, capacity: half
                ) { interleaved in
                  vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n,
                              FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
              }
            }
          }

          for b in 0..<bands {
            let from = edges[b]
            let to = max(from + 1, edges[b + 1])
            // **The average of the band where it covers bins, and the value
            // *between* bins where it does not.** A band narrower than a bin —
            // which every band in the bass is — otherwise repeats its
            // neighbour's number exactly, and a stack of bands all reading the
            // same bin is the blocky bottom the first version drew.
            var loudest: Float = 0
            if to - from >= 2 {
              var sum: Float = 0
              for bin in from..<min(to, half) { sum += magnitudes[bin] }
              loudest = sum / Float(min(to, half) - from)
            } else {
              let exact = centres[b]
              let low = min(half - 1, max(0, Int(exact)))
              let high = min(half - 1, low + 1)
              let part = Float(exact - Double(low))
              loudest = magnitudes[low] * (1 - part) + magnitudes[high] * part
            }
            // Decibels, floored where a room is silent. The scale is what makes
            // a spectrum readable at all: linear, everything but the bass is
            // black.
            let scaled = loudest / Float(size)
            let decibels = scaled > 0.0000001 ? 20 * log10f(scaled) : -100
            picture[slice * bands + b] =
              max(0, min(1, (decibels + 80) / 80))
          }
          slice += 1
          nextSlice += hop
        }
        frame += 1
      }
    }

    let bytes = picture.withUnsafeBufferPointer { Data(buffer: $0) }
    return FlutterStandardTypedData(float32: bytes)
  }

  // MARK: small things

  /// The format id as the four characters it has always been.
  ///
  /// Trimmed of spaces and of a leading dot: Core Audio pads `aac ` to four and
  /// tags mp3 as `.mp3`, and both of those are the tagging's business rather
  /// than something to put on screen. It read `.MP3` in the caption, which
  /// looks like a typo, and no format is named with a dot in front of it.
  private static func fourCC(_ id: UInt32) -> String {
    let bytes = [UInt8(id >> 24 & 255), UInt8(id >> 16 & 255),
                 UInt8(id >> 8 & 255), UInt8(id & 255)]
    let text = String(bytes: bytes, encoding: .ascii) ?? ""
    return text.trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }

  /// Bits a second, asked of the file rather than worked out from its size —
  /// which would count the cover art in the tags as music.
  private static func bitrate(url: URL, duration: Double) -> Int {
    var file: AudioFileID?
    guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr,
          let file
    else { return 0 }
    defer { AudioFileClose(file) }

    var rate: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    if AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate) == noErr,
       rate > 0 {
      return Int(rate)
    }
    return 0
  }
}

/// The `xverb/transfer` channel, macOS side: the file clipboard and
/// drag-and-drop.
///
/// **AppKit does the dragging; this hands it the files and reports back.**
/// Everything here is one of three things — the pasteboard, a drag arriving at
/// the window, or a drag leaving it — and none of it decides anything. Whether
/// a drop is a copy or a move is answered in Dart, because the answer depends
/// on which folder is under the pointer, and this half has never heard of
/// folders.
///
/// Two things are worth knowing before reading it:
///
/// - **The answers come back late.** AppKit asks `draggingUpdated` for an
///   operation and wants it *now*; Dart is on another thread and answers in a
///   millisecond or two. So every answer is remembered and the next question
///   is answered with the last one. A drag moves a few pixels between frames;
///   being one frame behind is invisible, and waiting on a round trip inside a
///   drag loop would not be.
/// - **A foreign drag is always answered "copy"**, whatever is about to happen
///   to the files. Saying "move" hands the other application permission to
///   delete files we have not finished reading. Our own drags are the
///   exception, and only because both ends of those are here.
enum TransferChannel {
  private static var channel: FlutterMethodChannel?
  private static weak var view: NSView?

  /// What Dart last said it would do with the drag now over the window.
  private static var lastOperation: NSDragOperation = []

  /// Kept alive for as long as a drag we started is running, and the way a
  /// drag arriving back at our own window is recognised as ours.
  private static var source: DragSource?

  /// The last press or drag of the left button, watched for rather than asked
  /// about.
  ///
  /// AppKit takes a dragging session from the event that started it, and the
  /// event this needs is the mouse drag happening right now. Asking
  /// `NSApp.currentEvent` for it does not work: by the time Dart has decided a
  /// press has become a drag and sent word back across the channel, the
  /// application's current event is whatever arrived since — on a trackpad,
  /// measured here, a gesture event, every single time. So the mouse events are
  /// watched as they pass and the last one is kept.
  private static var lastMouse: NSEvent?

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "xverb/transfer",
      binaryMessenger: controller.engine.binaryMessenger)
    self.channel = channel
    self.view = controller.view

    // Passed straight back out again: this watches, it does not intercept.
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) {
      event in
      lastMouse = event
      return event
    }
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "ping":
        result(nil)
      case "clipboardWrite":
        result(write(arguments: call.arguments))
      case "clipboardRead":
        result(read())
      case "clipboardSerial":
        result(Int(NSPasteboard.general.changeCount))
      case "startDrag":
        startDrag(arguments: call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // --- The pasteboard ------------------------------------------------------

  /// Writes the files and answers with the pasteboard's new serial.
  ///
  /// The `move` flag is taken and dropped on the floor, and that is not an
  /// omission. macOS has no cut: Finder's own "Move Items Here" is decided at
  /// the paste, by the key held down then, and there is no pasteboard type
  /// that carries the intention. So a cut here is remembered on our side —
  /// see `FileClipboard` — and a paste into Finder copies, which is what a
  /// paste into Finder does from every other application on the machine.
  private static func write(arguments: Any?) -> Any? {
    guard let args = arguments as? [String: Any],
          let paths = args["paths"] as? [String]
    else { return 0 }

    let board = NSPasteboard.general
    board.clearContents()
    board.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
    return Int(board.changeCount)
  }

  private static func read() -> Any? {
    let board = NSPasteboard.general
    guard let urls = board.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    else { return nil }

    return [
      "paths": urls.map { $0.path },
      "move": false,
      "changeCount": Int(board.changeCount),
    ]
  }

  // --- A drag arriving -----------------------------------------------------

  /// Whether the drag now over the window is one we started.
  static func isOurs(_ info: NSDraggingInfo) -> Bool {
    guard let source = source else { return false }
    return (info.draggingSource as AnyObject) === source
  }

  /// Tells Dart where the drag is and answers with what it last said.
  static func over(_ info: NSDraggingInfo) -> NSDragOperation {
    guard let channel = channel else { return [] }
    channel.invokeMethod("dragOver", arguments: describe(info)) { answer in
      lastOperation = operation(named: answer as? String)
    }
    return lastOperation
  }

  static func left() {
    lastOperation = []
    channel?.invokeMethod("dragLeave", arguments: nil)
  }

  /// The drop itself. True when somebody here will take it.
  static func drop(_ info: NSDraggingInfo) -> Bool {
    guard let channel = channel, !lastOperation.isEmpty else { return false }
    var arguments = describe(info)
    arguments["intent"] = lastOperation.contains(.move) ? "move" : "copy"
    channel.invokeMethod("drop", arguments: arguments)
    lastOperation = []
    return true
  }

  /// What the window tells AppKit it is willing to do at all.
  ///
  /// Copy for anything from outside, whatever Dart is about to do with the
  /// files: a "move" here is permission for the other application to delete
  /// them the moment this call returns, and the copying has not started yet.
  /// A drag of our own is the one case where both ends are ours, so it may
  /// have the truth — which is what puts the right badge under the cursor.
  static func answer(for info: NSDraggingInfo) -> NSDragOperation {
    let wanted = over(info)
    if wanted.isEmpty { return [] }
    return isOurs(info) ? wanted : .copy
  }

  private static func describe(_ info: NSDraggingInfo) -> [String: Any] {
    let point = position(of: info)
    let flags = NSEvent.modifierFlags
    return [
      "x": point.x,
      "y": point.y,
      "paths": paths(of: info),
      "allowsMove": info.draggingSourceOperationMask.contains(.move),
      "keys": [
        "control": flags.contains(.control),
        "shift": flags.contains(.shift),
        "alt": flags.contains(.option),
        "meta": flags.contains(.command),
      ],
    ]
  }

  /// Where the drag is, in the coordinates Flutter draws in: logical pixels
  /// from the top left of the view.
  ///
  /// A point on macOS is already a logical pixel, so the scale factor does not
  /// come into it. What does is that AppKit counts up from the bottom of the
  /// window and Flutter counts down from the top.
  private static func position(of info: NSDraggingInfo) -> CGPoint {
    guard let view = view else { return .zero }
    let inView = view.convert(info.draggingLocation, from: nil)
    return CGPoint(
      x: inView.x,
      y: view.isFlipped ? inView.y : view.bounds.height - inView.y)
  }

  private static func paths(of info: NSDraggingInfo) -> [String] {
    let urls = info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.map { $0.path } ?? []
  }

  private static func operation(named answer: String?) -> NSDragOperation {
    switch answer {
    case "copy": return .copy
    case "move": return .move
    default: return []
    }
  }

  // --- A drag leaving ------------------------------------------------------

  /// Picks the files up and hands them to AppKit.
  ///
  /// The images are the files' own icons, laid out in a small stack under the
  /// pointer — which is what makes a drag out of this application look like a
  /// drag out of Finder rather than like a rectangle being moved about.
  ///
  /// The event this needs is the mouse-dragged one that is happening right
  /// now: Flutter told Dart about it a moment ago, Dart asked for this, and
  /// the same event is still the application's current one. Without one there
  /// is nothing to start a session from, and the drag is refused rather than
  /// faked — a synthesised event would begin a drag the mouse is not actually
  /// holding.
  /// The mouse event to start a dragging session from, or null when the mouse
  /// is not in the middle of a drag at all.
  ///
  /// The button being down is what makes the remembered event the right one: a
  /// drag is a gesture that is still happening, and an old mouse-down with
  /// nothing held is a click that finished a minute ago.
  private static func mouseNow() -> NSEvent? {
    if let current = NSApp.currentEvent,
       current.type == .leftMouseDragged || current.type == .leftMouseDown {
      return current
    }
    guard NSEvent.pressedMouseButtons & 1 != 0 else { return nil }
    return lastMouse
  }

  private static func startDrag(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let paths = args["paths"] as? [String],
          !paths.isEmpty,
          let view = view,
          let event = mouseNow()
    else { return result(nil) }

    let allowMove = args["allowMove"] as? Bool ?? true
    let items: [NSDraggingItem] = paths.enumerated().map { index, path in
      let url = NSURL(fileURLWithPath: path)
      let item = NSDraggingItem(pasteboardWriter: url)
      let icon = NSWorkspace.shared.icon(forFile: path)
      // Fanned down and to the right, a few pixels each, so a selection reads
      // as a stack of files rather than as one icon.
      let step = CGFloat(min(index, 4)) * 4
      let origin = view.convert(event.locationInWindow, from: nil)
      item.setDraggingFrame(
        NSRect(x: origin.x - 16 + step, y: origin.y - 16 - step,
               width: 32, height: 32),
        contents: icon)
      return item
    }

    let source = DragSource(allowMove: allowMove) { operation, screenPoint in
      self.source = nil
      // Whoever took the files is brought to the front, and only then is the
      // drag reported as over. See [revealReceiver].
      if !operation.isEmpty { revealReceiver(at: screenPoint) }
      switch operation {
      case .move: result("move")
      case .copy: result("copy")
      default: result(nil)
      }
    }
    self.source = source
    view.beginDraggingSession(with: items, event: event, source: source)
  }
}

extension TransferChannel {
  /// Brings the application that took the files to the front.
  ///
  /// **Because the question it asks is otherwise invisible.** Drop a file into
  /// a Finder window where that name is taken and Finder puts up "an older item
  /// named … already exists" — behind our window, because we are still the
  /// front application and Finder does not raise itself. From here the drag
  /// simply appeared to do nothing, which is how it shows up in use.
  ///
  /// The window under the point is asked for by geometry alone: the window
  /// list gives owners and bounds without any permission — it is titles that
  /// need one, and no title is read here. Ordinary windows only (layer 0), so
  /// the Dock, the menu bar and a screen saver are not "the receiver", and
  /// never our own process.
  ///
  /// Nothing is done to *their* window: the application is activated, which is
  /// what a person who has just put a file into it is looking at anyway.
  static func revealReceiver(at screenPoint: NSPoint) {
    guard let primary = NSScreen.screens.first,
          let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return }

    // AppKit counts up from the bottom of the primary screen; the window list
    // counts down from the top of it.
    let point = CGPoint(
      x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
    let mine = ProcessInfo.processInfo.processIdentifier

    // Front to back, which is the order the list arrives in. **The first
    // window under the point decides, whoever owns it** — including us. It is
    // not enough to skip our own windows and go on looking: a drop from one of
    // our panels into the other lands on our own window, and what is behind it
    // at that point is somebody else's — which is how a drag between two
    // panels came to raise Finder and Safari.
    for window in windows {
      guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
            let pid = window[kCGWindowOwnerPID as String] as? pid_t,
            let frame = window[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(
              dictionaryRepresentation: frame as CFDictionary),
            bounds.contains(point)
      else { continue }

      if pid == mine { return }
      let application = NSRunningApplication(processIdentifier: pid)
      if #available(macOS 14.0, *) {
        application?.activate()
      } else {
        application?.activate(options: [.activateIgnoringOtherApps])
      }
      return
    }
  }
}

/// The object AppKit asks what a drag of ours is allowed to do, and tells when
/// it is over.
///
/// One per drag, held by [TransferChannel] for exactly as long as the drag
/// lasts: it is also how a drag arriving back at our own window is recognised
/// as our own.
final class DragSource: NSObject, NSDraggingSource {
  init(allowMove: Bool,
       ended: @escaping (NSDragOperation, NSPoint) -> Void) {
    self.allowMove = allowMove
    self.ended = ended
  }

  private let allowMove: Bool
  private let ended: (NSDragOperation, NSPoint) -> Void

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    // Outside the application as well as inside it: a file manager's whole
    // purpose is that the files it is showing are the machine's files, and a
    // drag that only works over our own window would say otherwise.
    return allowMove ? [.copy, .move] : .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    ended(operation, screenPoint)
  }
}

/// The `xverb/window` channel, macOS side: **the window itself, done here
/// rather than asked of a plugin.**
///
/// **Why this exists.** The window used to be `window_manager`'s and the
/// backdrop `flutter_acrylic`'s, and both are plugins. A plugin reaches its
/// window through `registrar.view?.window` — and the moment the engine is told
/// to accept several views there is no such view: `window_manager` force
/// unwraps it and the application dies inside `ensureInitialized()`, before a
/// single frame, with *Swift runtime failure: force unwrapped a nil value*.
/// Measured here on 3.47.2. Several views is the whole of detaching a view
/// into a window of its own, so the window layer stops being a plugin and
/// lives where the `NSWindow` is in hand and nothing has to answer anything.
///
/// It does four jobs: the window wears no bar of the platform's, it stays
/// hidden until Flutter has painted, it is made of glass as the appearance
/// asks, and the three buttons and the drag act on it. The fade of a window
/// that is not in front is [BackdropChannel]'s and stays there.
///
/// Written in this file for the reason [ShellChannel] gives: a new file means
/// editing the Xcode project.
enum WindowChannel {
  private static var channel: FlutterMethodChannel?
  private static weak var main: NSWindow?

  /// The glass behind each window, by the window it is in. **Not one field:**
  /// the application is about to have more than one window, and the second
  /// one asking for glass must not be handed the first one's.
  private static var glass: [ObjectIdentifier: NSVisualEffectView] = [:]

  /// The shape last told to Dart, so a resize that changes nothing — and
  /// AppKit sends a great many — costs no message.
  private static var toldMaximized: Bool?

  /// What the window comes up as. The same figures the `WindowOptions` it
  /// replaces carried, so nothing about the first frame moves.
  private static let startSize = NSSize(width: 1280, height: 800)
  private static let floorSize = NSSize(width: 640, height: 420)

  /// The engine, for the one thing that cannot be asked of it through a
  /// channel: where its text input lives. See [carryTextInput].
  private static weak var engine: FlutterEngine?

  static func attach(window: NSWindow, engine: FlutterEngine) {
    main = window
    self.engine = engine
    let channel = FlutterMethodChannel(
      name: "xverb/window", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
    self.channel = channel

    strip(window)
    // **AppKit restores a window's frame, and it does it after this.** The
    // size set here came out as 1089 wide on the first run of this code,
    // because state restoration put back the frame of an older session once
    // `awakeFromNib` had returned — where the package this replaces set the
    // size from Dart, long after restoration, and so never saw it. The window
    // is told not to be restored at all, and the size is said again at `show`,
    // which is after everything AppKit does on its own.
    window.isRestorable = false
    window.setContentSize(startSize)
    window.center()
    // **Hidden until there is something painted to put in it.** A window that
    // comes up grey and fills a moment later is the application jumping in
    // front of whoever opened it. `show` is sent after the first frame.
    window.orderOut(nil)

    // **Typed text follows the keyboard.** The first window is given it now,
    // because it may take the keyboard before anything is listening.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { note in
      guard let became = note.object as? NSWindow else { return }
      carryTextInput(to: became)
      tellWhoHasTheKeyboard()
    }
    // And when one gives it up, so that the application can say which window
    // has it now — or that none of them has. Asked on the next turn, because
    // at this moment the window that is taking it has not taken it yet.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { _ in
      DispatchQueue.main.async { tellWhoHasTheKeyboard() }
    }
    carryTextInput(to: window)
    // **Held, not set once**: see [point].
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      mindTextInput()
    }
  }

  // --- Which window is being typed into ------------------------------------

  /// **Says which window has the keyboard, by the address Dart knows it by.**
  ///
  /// Flutter keeps one focus for the whole application rather than one per
  /// window: every key goes to whatever took the focus last, wherever that
  /// is. So a view detached into a window of its own took the focus with it,
  /// and from then on the commander's own keys — F3, Ctrl+Q — were acted on
  /// by the detached window while the hand was in the first one. Measured,
  /// not read: the focus was in view 2 while view 1 was the window being
  /// typed into.
  ///
  /// The platform knows which window that is, so it says so and Dart moves
  /// the focus there. Zero is the window the application started in; no
  /// address at all means no window of ours has the keyboard.
  private static func tellWhoHasTheKeyboard() {
    var args: [String: Any] = [:]
    if let key = NSApp.keyWindow, flutterController(in: key) != nil {
      args["handle"] = NSNumber(value: addressOf(key))
    }
    channel?.invokeMethod("keyboard", arguments: args)
  }

  /// The number Dart holds a window by — the same pointer the windowing API
  /// handed it, which is how [named] finds a window again. The window the
  /// application started in has no such address on the Dart side, so it is
  /// nought.
  private static func addressOf(_ window: NSWindow) -> UInt {
    if window === main { return 0 }
    return UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
  }

  // --- Where typed text is turned into text --------------------------------

  /// **The embedder keeps one text input view and puts it in the window of
  /// the controller it calls the application's own** — the implicit view's.
  /// With several views on the engine there is no such controller, so that
  /// view is left in no window at all: every letter typed goes nowhere, while
  /// the keys themselves arrive as usual and everything looks alive. A rename
  /// box nobody can type into.
  ///
  /// So it is carried. The window that takes the keyboard takes it, which is
  /// the only arrangement that can be right with more than one window: there
  /// is one such view and only one window is being typed into.
  private static func carryTextInput(to window: NSWindow) {
    guard let controller = flutterController(in: window),
      let content = window.contentView,
      let plugin = textInput
    else { return }
    if plugin.superview !== content {
      plugin.removeFromSuperview()
      content.addSubview(plugin)
    }
    point(plugin, at: controller)
  }

  /// **Which window's key presses it is passing on.** The view keeps this
  /// inside itself and the embedder sets it from the controller it calls the
  /// application's own — which, with several views, does not exist. It is
  /// also cleared from inside a private method, with no moment to hook, so it
  /// is held rather than set once: every press that arrives while it is empty
  /// is a press the application never hears.
  private static func point(_ plugin: NSView, at controller: FlutterViewController) {
    for name in ["currentViewController", "originalViewController"] {
      guard class_getInstanceVariable(type(of: plugin), "_" + name) != nil
      else { continue }
      plugin.setValue(controller, forKey: name)
    }
  }

  /// Puts the text input back in order if it has been emptied: it belongs to
  /// the window that has the keyboard, pointed at that window's controller.
  private static func mindTextInput() {
    guard let key = NSApp.keyWindow, flutterController(in: key) != nil,
      let plugin = textInput
    else { return }
    if plugin.superview !== key.contentView
      || plugin.value(forKey: "currentViewController") == nil
    {
      carryTextInput(to: key)
    }
  }

  /// The embedder's text input view, which is in no header. A version of
  /// Flutter that renames it costs this application its typing, and nothing
  /// else — which is why it is read through a selector that may answer
  /// nothing rather than assumed.
  private static var textInput: NSView? {
    let name = Selector(("textInputPlugin"))
    guard let engine = engine, engine.responds(to: name) else { return nil }
    return engine.perform(name)?.takeUnretainedValue() as? NSView
  }

  /// What the window is made of, for the log on the Dart side.
  ///
  /// **Because the window cannot be photographed from outside.** macOS will
  /// not hand a screen capture to a script without the permission, and
  /// `CGWindowListCreateImage` is gone, so the window is asked to describe
  /// itself instead: the material behind it, whether it is opaque, and
  /// whether the glass really is below the drawing. Cheap, and the one check
  /// that the backdrop is what it claims.
  private static func describe(_ window: NSWindow) -> String {
    let key = ObjectIdentifier(window)
    guard let effect = glass[key] else { return "no glass" }
    let frame = window.contentView?.superview
    let below =
      (frame?.subviews.firstIndex(of: effect)).map { $0 == 0 } ?? false
    return
      "material=\(effect.material.rawValue) state=\(effect.state.rawValue) "
      + "opaque=\(window.isOpaque) belowDrawing=\(below) "
      + "size=\(Int(effect.frame.width))x\(Int(effect.frame.height))"
  }

  /// The application's own look on a window: **no bar and no buttons of the
  /// platform's**, because the title bar is drawn in Dart on every desktop,
  /// and a floor under how small it may be made.
  private static func strip(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    // The bar is dragged from the press Dart saw; a window that also moved
    // when its background was dragged would move twice.
    window.isMovableByWindowBackground = false
    window.minSize = floorSize
  }

  private static func handle(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    // **Which window is being spoken about.** A call with no address is about
    // the window the application started in, which this side holds; a call
    // with one is about a window the framework made, whose address only the
    // windowing API knows — so Dart sends it across and the window is found
    // from it. The address is good only while that window is alive, which is
    // why it is read and used in the same breath rather than kept.
    guard let window = named(args) else {
      result(nil)
      return
    }
    switch call.method {
    case "adopt":
      // A window the framework made comes up wearing the platform's bar and
      // none of the application's look. This side is the only one holding an
      // `NSWindow`, so it is told where the new one is and does to it what it
      // did to the first.
      strip(window)
      result(nil)
    case "setClientSize":
      // The windowing API's own size is the frame's, worked out with a bar
      // this application has taken off, so it comes out a bar's height wrong.
      if let size = sized(args) { setContent(window, size) }
      result(nil)
    case "handle":
      result(
        NSNumber(
          value: UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())))
    case "show":
      // The size is said here as well as at birth: see [attach] on the frame
      // AppKit restores behind our back.
      if window.frame.size != startSize {
        window.setContentSize(startSize)
        window.center()
      }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "raise":
      // One view is one thing wherever it is: asked for again while it is
      // already in a window of its own, that window comes forward rather
      // than a second copy being made.
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    case "minimize":
      window.miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      window.zoom(nil)
      result(nil)
    case "isMaximized":
      result(window.isZoomed)
    case "requestClose":
      // Through the platform, not around it: `performClose` is what the menu
      // and Cmd+W do, so the one way out is the one that is tested.
      window.performClose(nil)
      result(nil)
    case "destroy":
      window.delegate = nil
      window.close()
      result(nil)
    case "startDrag":
      // The event the press came in on is the one the window is dragged by;
      // without it Cocoa has nothing to follow.
      if let event = NSApp.currentEvent { window.performDrag(with: event) }
      result(nil)
    case "backdrop":
      setGlass(
        on: window,
        backdrop: (args["backdrop"] as? NSNumber)?.intValue ?? 0)
      result(describe(window))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The backdrop, as the four the settings offer.
  ///
  /// **The same materials the package used**, so the window looks exactly as
  /// it did: `flutter_acrylic` on macOS ignores the colour and the dark flag
  /// it is handed and sets a material and nothing else — `windowBackground`
  /// for opaque, `fullScreenUI` for acrylic and for mica, and
  /// `underWindowBackground` for transparent. Those are
  /// `WindowEffectToMaterialConverter`'s own answers, read rather than
  /// guessed, and they are repeated here.
  ///
  /// **The glass goes behind everything Flutter draws.** The view Flutter
  /// paints into *is* the window's content view, so an effect view added
  /// inside it would sit over the drawing rather than under it; the one place
  /// truly behind is the frame the window hangs its content on. That is also
  /// what keeps the fade in [BackdropChannel] honest — the content's alpha
  /// reaches the drawing alone and the glass is the window's to carry.
  ///
  /// **It is held active.** The effect view follows the window's own state by
  /// default, so the application went flat the moment another window took the
  /// keyboard; held active it stays frosted whichever window is in front.
  private static func setGlass(on window: NSWindow, backdrop: Int) {
    let material: NSVisualEffectView.Material
    switch backdrop {
    case 1, 2: material = .fullScreenUI  // acrylic, mica
    case 3: material = .underWindowBackground  // transparent
    default: material = .windowBackground  // opaque
    }

    // Nothing shows where Flutter has not drawn: the view it paints into is
    // opaque until it is told not to be, and an opaque metal layer with
    // nothing behind it is black.
    window.isOpaque = false
    window.backgroundColor = .clear
    let painter = flutterController(in: window)
    painter?.backgroundColor = .clear

    guard let content = window.contentView else { return }
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.clear.cgColor

    let key = ObjectIdentifier(window)
    if let had = glass[key] {
      had.material = material
      return
    }
    guard let frame = content.superview else { return }
    let effect = WindowGlass()
    effect.material = material
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.frame = frame.bounds
    effect.autoresizingMask = [.width, .height]
    frame.addSubview(effect, positioned: .below, relativeTo: nil)
    glass[key] = effect
  }

  /// The window a call is about: the application's first, or one the
  /// framework made and handed Dart the address of.
  private static func named(_ args: [String: Any]) -> NSWindow? {
    guard let address = (args["handle"] as? NSNumber)?.uintValue else {
      return main
    }
    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return nil }
    return Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
  }

  private static func sized(_ args: [String: Any]) -> NSSize? {
    guard let w = (args["width"] as? NSNumber)?.doubleValue,
      let h = (args["height"] as? NSNumber)?.doubleValue,
      w > 0, h > 0
    else { return nil }
    return NSSize(width: w, height: h)
  }

  /// The size of what the application draws, **with the window's top left
  /// kept where it is**. Cocoa measures a window from its bottom left, so a
  /// window simply given a new size grows downwards off its own head.
  private static func setContent(_ window: NSWindow, _ size: NSSize) {
    let top = window.frame.maxY
    window.setContentSize(size)
    var frame = window.frame
    frame.origin.y = top - frame.height
    window.setFrame(frame, display: true)
  }

  private static func flutterController(
    in window: NSWindow
  ) -> FlutterViewController? {
    guard let root = window.contentViewController else { return nil }
    if let flutter = root as? FlutterViewController { return flutter }
    for child in root.children {
      if let flutter = child as? FlutterViewController { return flutter }
    }
    return nil
  }

  // --- What the window says about itself ------------------------------------

  static func closing(_ window: NSWindow) {
    guard window === main else { return }
    channel?.invokeMethod("closing", arguments: nil)
  }

  static func front(_ window: NSWindow, _ inFront: Bool) {
    guard window === main else { return }
    channel?.invokeMethod(inFront ? "focus" : "blur", arguments: nil)
  }

  static func shapeChanged(_ window: NSWindow) {
    guard window === main else { return }
    let maximized = window.isZoomed
    if toldMaximized == maximized { return }
    toldMaximized = maximized
    channel?.invokeMethod("shape", arguments: ["maximized": maximized])
  }
}

/// The glass under the application.
///
/// **It must be blind to the hand.** A plain `NSVisualEffectView` tells AppKit
/// that a press on it may move the window, and AppKit takes it at its word:
/// every press anywhere in the window would go into dragging the window and
/// the application would never be told. It is decoration, so it refuses the
/// hit test outright and the hand always reaches what is drawn above it.
private final class WindowGlass: NSVisualEffectView {
  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
