# Plugins on Android and iOS

The core runs fine on both. The plugin system does not, and the reason is worth
writing down properly, because it shapes what mobile builds can ever be.

## Why the desktop approach does not carry over

Desktop plugins work by spawning `python3` as a child process and speaking
JSON-RPC over its stdio. Two separate things break that on mobile:

**iOS forbids it twice over.** An App Store app cannot `fork`/`exec` another
binary — there is no interpreter to launch and no way to launch one. And App
Review guideline 2.5.2 forbids downloading code that introduces or changes app
functionality. A plugin folder the user installs is exactly that. Both problems
are policy plus sandbox, not engineering; no amount of cleverness routes around
them.

**Android has no interpreter to spawn.** Processes can be started, but nothing
ships Python. Getting one requires embedding a runtime (Chaquopy,
python-for-android) into the Android build — real work, tens of megabytes, and
an in-process interpreter rather than the isolated child process that makes the
desktop design forgiving of crashes.

## What shipped instead

Rather than leave mobile empty, the app grew a second runtime, taking the same
route Blender does for everything that is not an add-on: **describe it as data
and compose primitives the application already ships.**

A declarative extension is a `plugin.json` with a `render` block. No code runs,
so `PythonRuntime` is never consulted and nothing is downloaded and executed —
which is precisely what makes it acceptable under App Review 2.5.2. The bundled
text, hex, image, CSV and JSON viewers are all declarative and load identically
on every platform.

So the position today: **mobile builds get the core plus every declarative
extension; only Python plugins are gated off**, and the plugin manager says so
instead of failing mysteriously. What mobile still lacks is network transports,
because a file system cannot be described declaratively.

## The options, and what each costs

### A. Declarative extensions — done

Viewing works everywhere. Cheap, no store exposure, and users can even sideload
their own declarative extensions on iOS, since a JSON file is data. Bounded by
the primitive set: no transports, no new formats.

### B. Bundled Dart plugins — the recommended next step for transports

Add a second runtime kind alongside `python`: plugins written in Dart and
compiled into the app. They register through the *same* extension points —
a viewer, a `FileSystemProvider`, a command — and the panels cannot tell the
difference.

This is cheap because the registry is already runtime-agnostic. `RegisteredViewer`
holds a closure, not an RPC handle. `FileSystemRegistry` holds a
`FileSystemProvider`, and `RemoteFileSystemProvider` is just one implementation
of it. A Dart plugin registers directly, with no protocol in between. Nothing in
the current design has to be undone.

What it buys: mobile gets the common cases — text and image viewing, an FTP or
SFTP transport — with no App Store exposure, because the code ships inside the
binary. What it does not buy: third-party extensibility on mobile. Users still
cannot add plugins there.

### C. Embedded CPython running bundled scripts

Link CPython into the app and run the *shipped* Python plugins in-process. Legal
on iOS as long as nothing is downloaded, and it keeps a single plugin language
across all platforms.

Costs: a large binary, a per-platform build story, and losing process isolation —
a plugin that segfaults now takes the app with it. Worth it only if the plugin
catalogue grows large enough that maintaining Dart twins of everything hurts more
than this does.

### D. Remote plugin host

The phone connects over TCP to an xverb running on a desktop, which hosts
the Python plugins and proxies the same JSON-RPC. The transport abstraction
already allows it — a remote host is another `PluginHost` implementation.

This is genuinely useful for "browse the NAS through my PC", and it sidesteps
every store rule because no code is downloaded. But it needs a companion machine
running, plus pairing, authentication and network discovery. A feature in its own
right, not a fix for the plugin gap.

## Recommendation

**A** is built. Do **B** when mobile needs a network transport — it is a
contained piece of work the architecture already accommodates, since
`RemoteFileSystemProvider` is only one implementation of `FileSystemProvider`.
Treat **C** and **D** as things to reach for only if real demand shows up.

## Things the mobile UI already does

- Below 720 logical pixels the two panels collapse into one panel with a
  Left/Right tab strip, so the dual-pane model survives on a phone.
- The F-key bar turns into an icon bar with the same commands.
- Long-press marks an entry, standing in for Insert.
- Roots come from `path_provider` rather than drive letters: Documents,
  temporary storage, and external storage on Android.

## Things still unresolved on mobile

- Android scoped storage limits how much of the file system is reachable; the
  Storage Access Framework would be needed to go further.
- iOS sandboxing means only the app's own container and whatever the document
  picker hands over. A `UIDocumentPickerViewController` bridge is the way in.
- Neither platform is keyboard-first, so type-ahead navigation is currently
  unreachable without an external keyboard.
