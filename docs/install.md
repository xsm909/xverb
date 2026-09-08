# Installing

Two ways in: take a published release, or build it yourself. Neither needs the
other, and neither asks for administrator rights.

## From a release

A release is **two files** — the archive and the installer beside it — and
nothing is fetched while it installs. Put both on the machine and run the
installer:

```sh
sh install.sh          # for you: ~/Applications, %LOCALAPPDATA% or ~/.local
sudo sh install.sh     # for everyone on the machine
```

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

`sh install.sh` rather than `./install.sh`, because a file that came out of a
browser download is not executable, and `sudo ./install.sh` then reports
`command not found`, which says nothing about what is actually wrong.

The installer takes whichever it finds first: an application already unpacked
beside it, an archive beside it, the newest `xverb-*` archive in **Downloads**,
or — last — the newest release fetched from the release repository. So the two
files can simply be handed to someone: they land in Downloads together and the
script finds the other one. `--archive FILE` (`-Archive FILE` on Windows) names
one outright.

### One line, and nothing to unpack

```sh
curl -fsSL https://raw.githubusercontent.com/xsm909/xverb-release/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/xsm909/xverb-release/main/install.ps1 | iex
```

Piped into a shell there is no script on disk to look beside, so this goes
straight to [the release repository][releases], takes the newest release,
checks it against the `.sha256` published with it and installs it. **A sum that
does not match ends the run** — nothing is unpacked, and the copy already on the
machine is untouched.

```sh
sh install.sh --release        # fetch the newest and install it
sh install.sh --check          # say what the newest is, install nothing
sh install.sh --to DIR         # portable: into DIR, registering nothing
sh install.sh --uninstall      # take it out again
```

On macOS this route has one practical advantage: a file downloaded by `curl`
carries no quarantine flag, so nothing has to be cleared before it will open.
An archive saved by a browser does carry one, and the installer clears it.

## Building it yourself

You need the [Flutter SDK][flutter] and the toolchain of the platform you are
building for — Xcode on macOS, MSVC on Windows, and the GTK development
packages on Linux. Nothing cross-compiles: each build is made on a machine of
that platform.

```sh
flutter pub get
flutter build macos --release      # or: windows, linux
```

What comes out is under `build/`: `xverb.app` on macOS, a folder holding
`xverb.exe` beside its DLLs on Windows, `bundle/` on Linux. Copy it where you
keep applications — or let the installer do it, which also registers the
application with the desktop. It installs whatever is **beside** it, so put it
there and run it from there:

```sh
cp tool/installer/install.sh build/macos/Build/Products/Release/
sh build/macos/Build/Products/Release/install.sh
```

## Where it lands

| | For you | For everyone |
| --- | --- | --- |
| macOS | `~/Applications` | `/Applications` |
| Windows | `%LOCALAPPDATA%\Programs\xverb` | `%ProgramFiles%\xverb` |
| Linux | `~/.local/lib/xverb` | `/opt/xverb` |

Linux also gets an `xverb` command and a desktop entry; Windows gets a Start
menu shortcut and an entry in *Installed apps*.

**Settings and installed plugins are never touched** — not when installing over
an older copy, and not when uninstalling. They live in the application support
directory of the platform, which the uninstaller leaves exactly where it is.

An uninstall only removes what the same scope installed: run as yourself it
will not reach into a copy installed for everyone, and says so rather than
asking for a password.

## Signing

The builds are **not signed or notarised**. On macOS a bundle that came out of
a browser is refused with a message about being damaged, which is Gatekeeper
rather than a broken download; the installer clears the quarantine flag it was
given, and the one-line install above never receives one. On Windows,
SmartScreen warns about an unrecognised publisher.

[releases]: https://github.com/xsm909/xverb-release
[flutter]: https://docs.flutter.dev/get-started/install
