# xverb

A dual-pane file manager in the Total Commander tradition, built entirely in
Flutter and extended with Python plugins.

The core does one thing: manage files in two panels. Everything else — network
transports, viewers, editors, archive support — is a plugin, the way it works in
Blender. That is a deliberate constraint, not a stage we are passing through:
FTP ships as a plugin precisely to prove the plugin surface is good enough to
build real features on.

Also like Blender, there are two ways to extend it. **Python plugins** run
arbitrary code in their own process. **Declarative extensions** are pure JSON
that composes the host's built-in render primitives — no code and no
interpreter, so by construction they need nothing the platform has to allow,
which is the answer for the platforms where executing plugin code is
impossible. Blender's node groups and theme extensions make the same trade.

**Status: early.** Windows, macOS and Linux are what this is developed and used
on. Android builds and runs, with little mileage on it. **iOS has not been
built yet** — it is a Flutter target, and nothing beyond that has been
verified. The table under [Platforms](#platforms) says which is which.

The list below is what the core *does*. For the shorter and more interesting
question — what it does that the one you already have does not — see
[docs/features.md](docs/features.md).

## What the core does

- Two panels, keyboard-driven, with the orthodox commander bindings
- Copy, move, delete, rename, create folder — across any two file systems
- The desktop's own clipboard and drag-and-drop: Ctrl+C, Ctrl+X and Ctrl+V
  exchange files with Explorer and Finder, and a selection can be dragged in or
  out with the mouse
- Marked-entry semantics: commands act on the marks, or on the cursor row
- A virtual file system with pluggable schemes (`file:` is the only built-in)
- File search with masks and text-in-file, whose results can be browsed as a
  panel listing — see [docs/search.md](docs/search.md)
- A path bar of buttons: the drive drops the drives-and-connections menu, every
  level above the current folder goes back to it
- Internal windows: settings, viewers and dialogs open inside the app, draggable
  and resizable, full-screen on a phone — see [docs/windows.md](docs/windows.md)
- An appearance settings page: colours, font, density, presets

## What the core deliberately does not do

- View or edit files. F3 asks the plugin registry which viewer claims the
  extension and hands the file over. With no viewer plugin installed, F3 says so.
- Speak FTP, SFTP, SMB, WebDAV or anything else. Those are plugins.
- Understand archives. Enter on a `.zip` opens it as a folder, but only because
  a plugin claims the extension and serves a `zip:` scheme; the core never
  learns what a ZIP is. See "Files that are really folders" in
  [docs/plugins.md](docs/plugins.md).
- Compare directories, sync folders, or run a shell. Folder comparison exists
  as a plugin in the collection; synchronising and a shell do not exist at all.

## Platforms

| Platform | Core | Declarative extensions | Python plugins |
| --- | --- | --- | --- |
| Windows | ● | ● | ● |
| macOS | ● | ● | ● |
| Linux | ● | ● | ● |
| Android | ○ | ○ | — |
| iOS | — | — | — |

● works, and is what the development happens on · ○ builds and runs, little
mileage on it · — not supported, or never tried.

Windows, macOS and Linux are what this is developed and used on. Android builds
and runs: there are no Python plugins there — embedding an interpreter is
impractical — and the network transports still need work. **iOS has not been
built yet.** Spawning a Python interpreter is not possible there at all, so the
Python column would be a dash whatever happened, but the other two columns are
dashes because nothing has been tried rather than because something failed. See
[docs/mobile.md](docs/mobile.md).

## Building

Requires the Flutter SDK (3.44 or newer).

```
flutter pub get
flutter run -d macos     # or windows, linux, android, ios
```

On Windows, `flutter pub get` needs Developer Mode enabled for symlink support
(`start ms-settings:developers`), and desktop builds need the Visual Studio
"Desktop development with C++" workload.

On Linux, the desktop build is compiled here rather than downloaded, so it
needs a toolchain and GTK's development files — on Debian and Ubuntu:

```
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
                 libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

The GStreamer packages are the ones worth a second look: without them the
build still succeeds, and the sound channel is compiled as a stub that answers
that this build cannot play — quietly correct, and not what anyone wants from
a release. See `linux/runner/CMakeLists.txt`.

**If pictures come out black, garbled or pixelated on Linux, look at the
graphics driver before looking here.** Flutter draws through Impeller on
OpenGL ES, and on the `nouveau` driver it renders image textures wrong while
text — which goes through the font path — stays perfect, so the application
looks fine apart from every picture in it. Reproduced with a stock
`flutter create` app showing one PNG: black on the GPU, correct under
`LIBGL_ALWAYS_SOFTWARE=1`. There is no opt-out to reach for — a release bundle
takes neither engine switches on its command line nor `FLUTTER_LINUX_RENDERER`
values other than a `software` one that aborts — so the answer is the
proprietary NVIDIA driver, or `LIBGL_ALWAYS_SOFTWARE=1` until it is installed.

## Installing

A release is **two files** — the archive and the installer beside it. With both
in place nothing is fetched while it installs: the machine it lands on needs no
clone, no Flutter SDK and no network. Run the installer on its own and it will
fetch the newest release itself and check it against its published sum. Put
both anywhere, Downloads being the obvious place, and run the installer:

```
sh install.sh                                             # macOS, Linux
sudo sh install.sh                                        # for everyone

powershell -ExecutionPolicy Bypass -File install.ps1      # Windows
```

It is `sh install.sh` rather than `./install.sh` because a file that came out
of a browser download is not executable. The installer takes whichever it finds
first: an application already unpacked beside it, an archive beside it, the
newest `xverb-*` archive in Downloads — the real one, read from the desktop's
own configuration — or the newest release fetched from
[xsm909/xverb-release](https://github.com/xsm909/xverb-release) and checked
against its published sum.

### Signing, quarantine, and what the installer does

The bundles are **not signed and not notarised**. A Developer ID costs $99 a
year and this is one person at an early stage, so it has not been paid for yet.
There is nothing to read into that beyond the money.

It matters most on macOS. A file that came out of a browser carries a
quarantine flag, and an unsigned application carrying that flag is one macOS
refuses to open at all — not with a warning, but outright. **So the installer
removes the flag from the copy it installs**, with
`xattr -d com.apple.quarantine` on the installed bundle. That is Gatekeeper
being stepped around on your behalf, and it is written here rather than left to
be found in the source. Windows is the same shape of thing at a lower stake:
the installer is an unsigned script, which is why it is run as
`powershell -ExecutionPolicy Bypass -File install.ps1`.

If you would rather not hand that over, there are two other ways in. Unpack the
archive yourself and clear the flag by hand — the same command, run by you
instead of by a script. Or build it: see [Building](#building) above.

Every archive has its own `.sha256` lying beside it in the
[release folder](https://github.com/xsm909/xverb-release/tree/main/release).
That file is the published sum, and it is the one the installer checks against
when it fetches a release itself. Check it before you run anything:

```
shasum -a 256 xverb-*-macos-arm64.tar.gz                    # macOS
sha256sum xverb-*-linux-x64.tar.gz                          # Linux
Get-FileHash xverb-*-windows-x64.zip -Algorithm SHA256      # Windows
```

Meant to come next, with no date on any of it: an ad-hoc signature on the macOS
bundle, then a real one and notarisation, then a signed Windows installer.

| | Run as yourself | Run elevated |
| --- | --- | --- |
| macOS | `/Applications` if it is writable, otherwise `~/Applications` | `/Applications` |
| Windows | `%LOCALAPPDATA%\Programs\xverb` | the same folder — see below |
| Linux | `~/.local/lib/xverb` | `/opt/xverb` |

It installs where it can rather than failing with a permission error, so
neither `sudo` nor "Run as administrator" is required to end up with a working
application. Windows gets a Start menu shortcut and an Apps & features entry;
Linux gets an `xverb` command and a desktop entry.

**On Windows there is no all-users install, and that is deliberate.** Xverb
updates itself in place, and putting a new version in place is a rename inside
the folder the installed copy sits in. Under `Program Files` that rename needs
administrator rights the running application does not have, so an update fails
there with an access error about a directory nobody mentioned. A program that
can replace itself has to live where it may write. Running the installer
elevated changes nothing but the account it installs for.

To remove it, `sh install.sh --uninstall` or `install.ps1 -Uninstall`.
Settings, connections and installed plugins are left in place.

The whole of it, including the one-line install and portable installs, is in
[docs/install.md](docs/install.md).


## Extensions

Settings → Plugins is a feed of everything the app knows about, searchable and
grouped by category. It reads
[xsm909/xverb-plugins](https://github.com/xsm909/xverb-plugins) —
the collection this project publishes — without being told to, and more
sources can be added by address. Install is one press; the folder lands in the
plugins directory shown on that page.

**Bundled** extensions ship inside the app and can be switched off but not
deleted. Those are the declarative viewers only — text, Markdown, image, table
and JSON — because pure data needs nothing the platform has to allow, which is
what the platforms where running plugin code is impossible require. Everything with code in it, FTP and SMB
included, comes from the collection.

Two directories are searched for installed plugins: the app's support
directory, and a `plugins` folder beside the executable, so a portable copy of
the app carries its plugins with it. A debug build also scans the working
directory, which `flutter run` sets to the project root — that is how a plugin
is worked on without reinstalling it after every edit.

`XVERB_PLUGINS` overrides the support directory outright, which is the
other way to point a build straight at a checkout of the collection. Settings →
Plugins always shows the directory actually in use, whatever the platform
decided it was.

### Connections

Transports that need credentials describe their form in the manifest, and the
app renders it. FTP gets the usual host, port, user, remote directory, TLS and
passive-mode fields; they are saved to `connections/ftp_connect.ini` in the
support directory, which is plain INI and safe to edit by hand.

Passwords are **not** written in the clear. By default nothing is saved and you
are asked when connecting; tick "Save the password" and it is encrypted with
your Windows account, so the file is useless to another account or another
machine. Where no key store is wired up the option is unavailable rather than
falling back to obfuscation.

### Declarative — data, no code

A viewer described as JSON over the host's primitives (`text`, `hex`, `image`,
`table`). The bundled text, image, CSV and JSON viewers are all just this:

```json
{
  "id": "com.example.csv", "apiVersion": 1, "runtime": "declarative",
  "viewers": [{
    "id": "example.csv", "title": "Table", "extensions": ["csv"], "priority": 20,
    "render": { "kind": "table", "source": "csv", "delimiter": "auto" }
  }]
}
```

### Python — real code

For anything the primitives cannot express. A plugin is a folder with a
`plugin.json` and an entry script, run as its own process.

**Plugins target Python 3.12.** The app runs one pinned interpreter of its own
rather than whatever the machine happens to have, so a plugin written once
behaves the same on every platform. See
[docs/plugins.md](docs/plugins.md#target-python-version) for what that rules in
and out.

```python
from xverb import Plugin, table

plugin = Plugin("com.example.zip")

@plugin.viewer("zip.list", "Contents", extensions=["zip"], priority=30)
def view(url):
    ...  # plugin.read_file(url) works on any file system, local or plugin-served

plugin.run()
```

The worked examples live in
[xsm909/xverb-plugins](https://github.com/xsm909/xverb-plugins):
`ftp` and `smb` (transports registering the `ftp:` and `smb:` schemes, stdlib
only) and `zip-viewer` (archive listing — the boundary case declarative
extensions cannot reach).

See [docs/plugins.md](docs/plugins.md) for the full API and protocol.

## Layout

```
lib/core/vfs/                 file system abstraction, local provider, copy engine
lib/core/plugins/             manifests, registry, extension points
lib/core/plugins/rpc/         JSON-RPC channel, Python process host, runtime probe
lib/core/plugins/declarative/ render primitives for code-free extensions
lib/core/settings/            appearance model and persistence
lib/state/                    panel and application state
lib/ui/                       panels, dialogs, settings, plugin-driven viewer
assets/python/                the xverb Python SDK, staged at startup
assets/plugins/               bundled declarative extensions
```

The Python plugins are not here: they live in
[xsm909/xverb-plugins](https://github.com/xsm909/xverb-plugins), one
folder each, and the app installs them from there.

## Licence

GNU General Public License, version 3 or later. See [LICENSE](LICENSE).

```
Copyright (C) 2026 xsm909

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.
```

A plugin is a separate program: it runs in its own process and talks to the app
over JSON-RPC, so it carries whatever licence its author chose. The plugins in
[xsm909/xverb-plugins](https://github.com/xsm909/xverb-plugins) say so
for themselves.
